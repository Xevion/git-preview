//! Allowlist sanitizer for raw HTML in Markdown, approximating GitHub's post-render filter.
//! Tags in `filtered_tags` are escaped as text (the GFM tagfilter rule); other unknown
//! tags are dropped while their contents are kept.

const std = @import("std");
const Writer = std.Io.Writer;

/// Rewrites URLs found in raw HTML; returned slices must outlive the render.
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

/// State that spans the raw HTML fragments of one document.
pub const State = struct {
    /// Open `<a>` depth, so images already inside a link are not wrapped in another.
    link_depth: u32 = 0,
    rewriter: UrlRewriter = .identity,
};

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

const Attr = struct { name: []const u8, value: ?[]const u8 };

const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
    attrs_src: []const u8,
    len: usize,
};

/// Writes a sanitized copy of the raw HTML `src`.
pub fn sanitize(state: *State, w: *Writer, src: []const u8) !void {
    var i: usize = 0;
    while (i < src.len) {
        const lt = std.mem.indexOfScalarPos(u8, src, i, '<') orelse {
            try w.writeAll(src[i..]);
            return;
        };
        try w.writeAll(src[i..lt]);
        const rest = src[lt..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.indexOf(u8, rest, "-->") orelse rest.len - 3;
            i = lt + end + 3;
            continue;
        }
        const tag = parseTag(rest) orelse {
            try w.writeAll("&lt;");
            i = lt + 1;
            continue;
        };
        i = lt + tag.len;
        if (inList(&filtered_tags, tag.name)) {
            try w.writeAll("&lt;");
            try writeEscapedText(w, rest[1 .. tag.len - 1]);
            try w.writeAll("&gt;");
        } else if (inList(&allowed_tags, tag.name)) {
            try writeTag(state, w, tag);
        }
    }
}

fn parseTag(s: []const u8) ?Tag {
    var i: usize = 1;
    const closing = i < s.len and s[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    const name = s[name_start..i];
    const attrs_start = i;
    var quote: u8 = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            const inner = std.mem.trimEnd(u8, s[attrs_start..i], " \t\r\n");
            const self_closing = std.mem.endsWith(u8, inner, "/");
            return .{
                .name = name,
                .closing = closing,
                .self_closing = self_closing,
                .attrs_src = if (self_closing) inner[0 .. inner.len - 1] else inner,
                .len = i + 1,
            };
        } else if (ch == '<') {
            return null;
        }
    }
    return null;
}

const AttrIterator = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *AttrIterator) ?Attr {
        const s = it.s;
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len) return null;
        const start = it.i;
        while (it.i < s.len and !std.ascii.isWhitespace(s[it.i]) and s[it.i] != '=' and s[it.i] != '/') it.i += 1;
        const name = s[start..it.i];
        if (name.len == 0) {
            it.i += 1;
            return it.next();
        }
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i >= s.len or s[it.i] != '=') return .{ .name = name, .value = null };
        it.i += 1;
        while (it.i < s.len and std.ascii.isWhitespace(s[it.i])) it.i += 1;
        if (it.i < s.len and (s[it.i] == '"' or s[it.i] == '\'')) {
            const q = s[it.i];
            const vstart = it.i + 1;
            const vend = std.mem.indexOfScalarPos(u8, s, vstart, q) orelse s.len;
            it.i = @min(vend + 1, s.len);
            return .{ .name = name, .value = s[vstart..vend] };
        }
        const vstart = it.i;
        while (it.i < s.len and !std.ascii.isWhitespace(s[it.i])) it.i += 1;
        return .{ .name = name, .value = s[vstart..it.i] };
    }
};

/// True for relative URLs and the schemes GitHub allows in raw HTML.
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

fn writeTag(state: *State, w: *Writer, tag: Tag) !void {
    const is_a = std.ascii.eqlIgnoreCase(tag.name, "a");
    const is_img = std.ascii.eqlIgnoreCase(tag.name, "img");
    if (tag.closing) {
        if (is_a and state.link_depth > 0) state.link_depth -= 1;
        try w.print("</{s}>", .{tag.name});
        return;
    }

    var img_src: ?[]const u8 = null;
    if (is_img) {
        var it: AttrIterator = .{ .s = tag.attrs_src };
        while (it.next()) |attr| {
            if (std.ascii.eqlIgnoreCase(attr.name, "src")) img_src = attr.value;
        }
        if (img_src) |src| {
            if (!safeUrl(src)) img_src = null;
        }
    }
    const resolved_src = if (img_src) |src| try state.rewriter.image(src) else null;
    const wrap = is_img and state.link_depth == 0 and resolved_src != null;
    if (wrap) {
        try w.writeAll("<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"");
        try w.writeAll(resolved_src.?);
        try w.writeAll("\">");
    }

    try w.print("<{s}", .{tag.name});
    var has_dir = false;
    var it: AttrIterator = .{ .s = tag.attrs_src };
    while (it.next()) |attr| {
        if (!inList(&allowed_attrs, attr.name)) continue;
        const is_href = std.ascii.eqlIgnoreCase(attr.name, "href");
        const is_src = std.ascii.eqlIgnoreCase(attr.name, "src");
        if (std.ascii.eqlIgnoreCase(attr.name, "dir")) has_dir = true;
        const value = attr.value orelse {
            try w.print(" {s}", .{attr.name});
            continue;
        };
        if ((is_href or is_src) and !safeUrl(value)) continue;
        try w.print(" {s}=\"", .{attr.name});
        if (std.ascii.eqlIgnoreCase(attr.name, "id") or std.ascii.eqlIgnoreCase(attr.name, "name")) {
            if (!std.mem.startsWith(u8, value, "user-content-")) try w.writeAll("user-content-");
            try writeAttrValue(w, value);
        } else if (is_src and is_img) {
            try w.writeAll(resolved_src orelse value);
        } else if (is_href and is_a) {
            try writeAttrValue(w, try state.rewriter.link(value));
        } else {
            try writeAttrValue(w, value);
        }
        try w.writeByte('"');
    }
    if (is_img) try w.writeAll(" style=\"max-width: 100%;\"");
    if (!has_dir and inList(&dir_auto_tags, tag.name)) try w.writeAll(" dir=\"auto\"");
    try w.writeAll(if (tag.self_closing and !is_img) " />" else ">");

    if (wrap) try w.writeAll("</a>");
    if (is_a and !tag.self_closing) state.link_depth += 1;
}

fn writeEscapedText(w: *Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(ch),
    };
}

/// Attribute values are copied as authored, only re-escaping the quote that delimits them.
fn writeAttrValue(w: *Writer, value: []const u8) !void {
    for (value) |ch| {
        if (ch == '"') try w.writeAll("&quot;") else try w.writeByte(ch);
    }
}

fn sanitizeToString(src: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var state: State = .{};
    try sanitize(&state, &out.writer, src);
    return out.toOwnedSlice();
}

test "matches GitHub's handling of the fixture HTML" {
    const cases = [_][2][]const u8{
        .{ "<script>alert(1)</script>", "&lt;script&gt;alert(1)&lt;/script&gt;" },
        .{ "<div style=\"color:red\" onclick=\"x()\">styled</div>", "<div dir=\"auto\">styled</div>" },
        .{ "<a name=\"anchor\"></a>", "<a name=\"user-content-anchor\"></a>" },
        .{ "<p align=\"center\">c</p>", "<p align=\"center\" dir=\"auto\">c</p>" },
        .{ "<img src=\"x.png\" width=\"10\">", "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"x.png\"><img src=\"x.png\" width=\"10\" style=\"max-width: 100%;\"></a>" },
        .{ "<a href=\"javascript:x\"><img src=\"b.svg\"></a>", "<a><img src=\"b.svg\" style=\"max-width: 100%;\"></a>" },
        .{ "<foo>kept</foo><!-- gone -->", "kept" },
    };
    for (cases) |case| {
        const got = try sanitizeToString(case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}
