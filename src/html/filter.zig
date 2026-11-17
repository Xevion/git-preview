//! GitHub's post-render pipeline over a real HTML5 DOM: sanitize raw-HTML regions,
//! then apply the filters GitHub runs on everything (image links, user-content ids).
//! Raw regions are delimited by `<!--gp-raw:NONCE-->` and `<!--gp-end:NONCE-->`.

const std = @import("std");
const c = @import("lexbor");
const emoji = @import("emoji.zig");
const dom = @import("dom.zig");
const localName = dom.localName;
const getAttr = dom.getAttr;
const hasAttr = dom.hasAttr;
const setAttr = dom.setAttr;
const remove = dom.remove;
const unwrap = dom.unwrap;
const Node = c.lxb_dom_node_t;
const Element = c.lxb_dom_element_t;

/// Rewrites URLs (e.g. relative images into data URIs); returned slices must outlive the call.
pub const UrlRewriter = struct {
    ctx: *anyopaque,
    imageFn: *const fn (ctx: *anyopaque, url: []const u8) anyerror![]const u8,
    linkFn: *const fn (ctx: *anyopaque, url: []const u8) anyerror![]const u8,

    pub fn image(self: UrlRewriter, url: []const u8) ![]const u8 {
        return self.imageFn(self.ctx, url);
    }

    pub fn link(self: UrlRewriter, url: []const u8) ![]const u8 {
        return self.linkFn(self.ctx, url);
    }

    pub const identity: UrlRewriter = .{ .ctx = undefined, .imageFn = passthrough, .linkFn = passthrough };

    fn passthrough(_: *anyopaque, url: []const u8) anyerror![]const u8 {
        return url;
    }
};

pub const Options = struct {
    nonce: []const u8,
    own_host: []const u8 = "github.com",
    rewriter: UrlRewriter = .identity,
};

/// Tags GFM's tagfilter neutralizes before parsing, so they survive only as text.
const filtered_tags = [_][]const u8{ "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext" };

const allowed_tags = [_][]const u8{
    "h1",      "h2",      "h3",      "h4",     "h5",         "h6",    "h7",         "h8",
    "br",      "b",       "i",       "strong", "em",         "a",     "pre",        "code",
    "img",     "tt",      "div",     "ins",    "del",        "sup",   "sub",        "p",
    "ol",      "ul",      "table",   "thead",  "tbody",      "tfoot", "blockquote", "dl",
    "dt",      "dd",      "kbd",     "q",      "samp",       "var",   "hr",         "ruby",
    "rt",      "rp",      "li",      "tr",     "td",         "th",    "s",          "strike",
    "summary", "details", "caption", "figure", "figcaption", "abbr",  "bdo",        "cite",
    "dfn",     "mark",    "small",   "span",   "time",       "wbr",   "picture",    "source",
};

const allowed_attrs = [_][]const u8{
    "abbr",             "accept",      "accept-charset", "accesskey",       "action",   "align",    "alt",
    "aria-describedby", "aria-hidden", "aria-label",     "aria-labelledby", "axis",     "border",   "cellpadding",
    "cellspacing",      "char",        "charoff",        "charset",         "checked",  "clear",    "cols",
    "colspan",          "color",       "compact",        "coords",          "datetime", "dir",      "disabled",
    "enctype",          "for",         "frame",          "headers",         "height",   "hreflang", "hspace",
    "ismap",            "label",       "lang",           "maxlength",       "media",    "method",   "multiple",
    "name",             "nohref",      "noshade",        "nowrap",          "open",     "progress", "prompt",
    "readonly",         "rel",         "rev",            "role",            "rows",     "rowspan",  "rules",
    "scope",            "selected",    "shape",          "size",            "span",     "start",    "summary",
    "tabindex",         "target",      "title",          "type",            "usemap",   "valign",   "value",
    "vspace",           "width",       "itemprop",       "id",              "href",     "src",      "srcset",
    "cite",             "longdesc",
};

/// Tags GitHub marks with `dir="auto"` so mixed-direction text lays out correctly.
const dir_auto_tags = [_][]const u8{ "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ol", "ul" };

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.ascii.eqlIgnoreCase(item, name)) return true;
    return false;
}

/// True for relative URLs and the schemes GitHub allows.
pub fn safeUrl(url: []const u8) bool {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return true;
    if (std.mem.indexOfAny(u8, trimmed[0..colon], "/?#") != null) return true;
    const scheme = trimmed[0..colon];
    for ([_][]const u8{ "http", "https", "mailto" }) |ok| {
        if (std.ascii.eqlIgnoreCase(scheme, ok)) return true;
    }
    return false;
}

/// True for absolute URLs pointing away from `own_host` and its subdomains.
pub fn isExternal(url: []const u8, own_host: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const rest = url[scheme_end + 3 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, "/:?#") orelse rest.len];
    if (std.ascii.eqlIgnoreCase(host, own_host)) return false;
    const sub = host.len > own_host.len and host[host.len - own_host.len - 1] == '.' and
        std.ascii.eqlIgnoreCase(host[host.len - own_host.len ..], own_host);
    return !sub;
}

/// Applies GFM's tagfilter: `<` opening a filtered tag becomes `&lt;` so the parser reads it as text.
pub fn writeTagFiltered(w: *std.Io.Writer, raw: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, i, '<')) |lt| : (i = lt + 1) {
        var name_start = lt + 1;
        if (name_start < raw.len and raw[name_start] == '/') name_start += 1;
        for (filtered_tags) |tag| {
            const end = name_start + tag.len;
            if (end > raw.len or !std.ascii.eqlIgnoreCase(raw[name_start..end], tag)) continue;
            if (end < raw.len and !(std.ascii.isWhitespace(raw[end]) or raw[end] == '>' or raw[end] == '/')) continue;
            try w.writeAll(raw[start..lt]);
            try w.writeAll("&lt;");
            start = lt + 1;
            break;
        }
    }
    try w.writeAll(raw[start..]);
}

/// Parses `fragment` as body content, runs the filters, and returns the serialized result.
pub fn finalize(gpa: std.mem.Allocator, fragment: []const u8, options: Options) ![]u8 {
    const doc = c.lxb_html_document_create() orelse return error.OutOfMemory;
    defer _ = c.lxb_html_document_destroy(doc);
    const ctx = c.lxb_dom_document_create_element(&doc.*.dom_document, "body", 4, null) orelse return error.OutOfMemory;
    const root: *Node = c.lxb_html_document_parse_fragment(doc, ctx, fragment.ptr, fragment.len) orelse return error.HtmlParse;

    var f: Filter = .{ .gpa = gpa, .doc = &doc.*.dom_document, .opts = options };
    try f.sanitize(root);
    try f.emojify(root);
    try f.linkImages(root);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var child: ?*Node = root.first_child;
    while (child) |ch| : (child = ch.next) {
        // The serialized string lives in the document's arena and is freed with it.
        var s = std.mem.zeroes(c.lexbor_str_t);
        if (c.lxb_html_serialize_tree_str(ch, &s) != c.LXB_STATUS_OK) return error.HtmlSerialize;
        try out.appendSlice(gpa, s.data[0..s.length]);
    }
    return out.toOwnedSlice(gpa);
}

const Filter = struct {
    gpa: std.mem.Allocator,
    doc: *c.lxb_dom_document_t,
    opts: Options,
    in_raw: bool = false,

    fn marker(f: *Filter, node: *Node) ?bool {
        const data: *c.lxb_dom_character_data_t = @ptrCast(node);
        const text = data.data.data[0..data.data.length];
        const prefix_len = "gp-raw:".len;
        if (text.len != prefix_len + f.opts.nonce.len or !std.mem.endsWith(u8, text, f.opts.nonce)) return null;
        if (std.mem.startsWith(u8, text, "gp-raw:")) return true;
        if (std.mem.startsWith(u8, text, "gp-end:")) return false;
        return null;
    }

    fn sanitize(f: *Filter, parent: *Node) anyerror!void {
        var cur: ?*Node = parent.first_child;
        while (cur) |node| {
            cur = node.next;
            switch (node.type) {
                c.LXB_DOM_NODE_TYPE_COMMENT => {
                    if (f.marker(node)) |raw| f.in_raw = raw;
                    remove(node);
                },
                c.LXB_DOM_NODE_TYPE_ELEMENT => {
                    const untrusted = f.in_raw;
                    const name = localName(node);
                    if (untrusted and inList(&filtered_tags, name)) {
                        remove(node);
                        continue;
                    }
                    if (untrusted) try f.cleanAttributes(node, name);
                    try f.sanitize(node);
                    if (untrusted and !inList(&allowed_tags, name)) unwrap(node);
                },
                else => {},
            }
        }
    }

    fn cleanAttributes(f: *Filter, node: *Node, name: []const u8) !void {
        const el: *Element = @ptrCast(node);
        const is_a = std.mem.eql(u8, name, "a");
        const is_img = std.mem.eql(u8, name, "img");
        var attr = c.lxb_dom_element_first_attribute_noi(el);
        while (attr) |a| {
            attr = c.lxb_dom_element_next_attribute_noi(a);
            var name_len: usize = 0;
            const attr_name_ptr = c.lxb_dom_attr_qualified_name(a, &name_len);
            const attr_name = attr_name_ptr[0..name_len];
            var value_len: usize = 0;
            const value_ptr = c.lxb_dom_attr_value_noi(a, &value_len);
            const value: []const u8 = if (value_ptr) |p| p[0..value_len] else "";

            const keep = inList(&allowed_attrs, attr_name) and
                !((std.mem.eql(u8, attr_name, "href") or std.mem.eql(u8, attr_name, "src")) and !safeUrl(value));
            if (!keep) {
                _ = c.lxb_dom_element_remove_attribute(el, attr_name_ptr, name_len);
                continue;
            }
            if ((std.mem.eql(u8, attr_name, "id") or std.mem.eql(u8, attr_name, "name")) and !std.mem.startsWith(u8, value, "user-content-")) {
                var buf: [256]u8 = undefined;
                const prefixed = std.fmt.bufPrint(&buf, "user-content-{s}", .{value}) catch continue;
                setAttr(el, attr_name, prefixed);
            } else if (is_a and std.mem.eql(u8, attr_name, "href")) {
                setAttr(el, attr_name, try f.opts.rewriter.link(value));
            } else if (is_img and std.mem.eql(u8, attr_name, "src")) {
                if (isExternal(value, f.opts.own_host)) setAttr(el, "data-canonical-src", value);
                setAttr(el, attr_name, try f.opts.rewriter.image(value));
            }
        }
        if (is_img) setAttr(el, "style", "max-width: 100%;");
        if (inList(&dir_auto_tags, name) and !hasAttr(el, "dir")) setAttr(el, "dir", "auto");
    }

    /// Replaces `:shortcode:` emoji in text, skipping code, as GitHub's emoji filter does.
    fn emojify(f: *Filter, parent: *Node) !void {
        var cur: ?*Node = parent.first_child;
        while (cur) |node| {
            cur = node.next;
            switch (node.type) {
                c.LXB_DOM_NODE_TYPE_ELEMENT => {
                    const name = localName(node);
                    if (!(std.mem.eql(u8, name, "pre") or std.mem.eql(u8, name, "code") or std.mem.eql(u8, name, "tt"))) try f.emojify(node);
                },
                c.LXB_DOM_NODE_TYPE_TEXT => try f.emojifyText(node),
                else => {},
            }
        }
    }

    fn emojifyText(f: *Filter, node: *Node) !void {
        const data: *c.lxb_dom_character_data_t = @ptrCast(node);
        const text = data.data.data[0..data.data.length];
        var m = emoji.next(text, 0) orelse return;
        var pending_start: usize = 0;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(f.gpa);
        while (true) {
            try buf.appendSlice(f.gpa, text[pending_start..m.start]);
            switch (m.emoji) {
                .unicode => |u| try buf.appendSlice(f.gpa, u),
                .custom => |name| {
                    try f.insertText(node, buf.items);
                    buf.clearRetainingCapacity();
                    try f.insertCustomEmoji(node, name);
                },
            }
            pending_start = m.end;
            m = emoji.next(text, m.end) orelse break;
        }
        try buf.appendSlice(f.gpa, text[pending_start..]);
        try f.insertText(node, buf.items);
        remove(node);
    }

    fn insertText(f: *Filter, before: *Node, text: []const u8) !void {
        if (text.len == 0) return;
        const t: *Node = @ptrCast(c.lxb_dom_document_create_text_node(f.doc, text.ptr, text.len) orelse return error.OutOfMemory);
        c.lxb_dom_node_insert_before(before, t);
    }

    fn insertCustomEmoji(f: *Filter, before: *Node, name: []const u8) !void {
        const img: *Node = @ptrCast(c.lxb_dom_document_create_element(f.doc, "img", 3, null) orelse return error.OutOfMemory);
        const el: *Element = @ptrCast(img);
        var title_buf: [128]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, ":{s}:", .{name});
        var src_buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "https://github.githubassets.com/images/icons/emoji/{s}.png", .{name});
        setAttr(el, "class", "emoji");
        setAttr(el, "title", title);
        setAttr(el, "alt", title);
        setAttr(el, "src", src);
        setAttr(el, "height", "20");
        setAttr(el, "width", "20");
        setAttr(el, "align", "absmiddle");
        c.lxb_dom_node_insert_before(before, img);
    }

    /// Wraps every image outside a link in a link to itself, as GitHub does; emoji images are exempt.
    fn linkImages(f: *Filter, parent: *Node) !void {
        var cur: ?*Node = parent.first_child;
        while (cur) |node| {
            cur = node.next;
            if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) continue;
            const name = localName(node);
            if (std.mem.eql(u8, name, "a")) continue;
            if (!std.mem.eql(u8, name, "img")) {
                try f.linkImages(node);
                continue;
            }
            const el: *Element = @ptrCast(node);
            const src = getAttr(el, "src") orelse continue;
            if (std.mem.eql(u8, getAttr(el, "class") orelse "", "emoji")) continue;
            const link: *Node = @ptrCast(c.lxb_dom_document_create_element(f.doc, "a", 1, null) orelse return error.OutOfMemory);
            const link_el: *Element = @ptrCast(link);
            setAttr(link_el, "target", "_blank");
            setAttr(link_el, "rel", if (hasAttr(el, "data-canonical-src")) "noopener noreferrer nofollow" else "noopener noreferrer");
            setAttr(link_el, "href", src);
            c.lxb_dom_node_insert_before(node, link);
            c.lxb_dom_node_remove(node);
            c.lxb_dom_node_insert_child(link, node);
        }
    }
};

fn finalizeRaw(raw: []const u8) ![]u8 {
    const gpa = std.testing.allocator;
    var src: std.Io.Writer.Allocating = .init(gpa);
    defer src.deinit();
    try src.writer.writeAll("<!--gp-raw:n0nce-->");
    try writeTagFiltered(&src.writer, raw);
    try src.writer.writeAll("<!--gp-end:n0nce-->");
    return finalize(gpa, src.written(), .{ .nonce = "n0nce" });
}

test "raw HTML is sanitized the way GitHub does" {
    const cases = [_][2][]const u8{
        .{ "<script>alert(1)</script>", "&lt;script&gt;alert(1)&lt;/script&gt;" },
        .{ "<div style=\"color:red\" onclick=\"x()\">styled</div>", "<div dir=\"auto\">styled</div>" },
        .{ "<a name=\"anchor\"></a>", "<a name=\"user-content-anchor\"></a>" },
        .{ "<p align=\"center\">c</p>", "<p align=\"center\" dir=\"auto\">c</p>" },
        .{ "<img src=\"x.png\" width=\"10\">", "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"x.png\"><img src=\"x.png\" width=\"10\" style=\"max-width: 100%;\"></a>" },
        .{ "<a href=\"javascript:x\"><img src=\"b.svg\"></a>", "<a><img src=\"b.svg\" style=\"max-width: 100%;\"></a>" },
        .{ "<foo>kept</foo><!-- gone -->", "kept" },
        .{ "<img src=\"a.png\">\n<img src=\"b.png\">", "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"a.png\"><img src=\"a.png\" style=\"max-width: 100%;\"></a>\n<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"b.png\"><img src=\"b.png\" style=\"max-width: 100%;\"></a>" },
        .{ "<svg><path d=\"x\"/></svg><img src=x onerror=alert(1)>", "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"x\"><img src=\"x\" style=\"max-width: 100%;\"></a>" },
    };
    for (cases) |case| {
        const got = try finalizeRaw(case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "trusted markup outside raw markers is left alone" {
    const gpa = std.testing.allocator;
    const got = try finalize(gpa, "<div class=\"markdown-alert\"><svg class=\"octicon\"><path d=\"M0\"></path></svg></div><!--gp-raw:wrong--><b class=\"x\">b</b>", .{ .nonce = "n0nce" });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("<div class=\"markdown-alert\"><svg class=\"octicon\"><path d=\"M0\"></path></svg></div><b class=\"x\">b</b>", got);
}
