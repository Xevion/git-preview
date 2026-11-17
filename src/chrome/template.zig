//! Turns a live github.com page into a static template: scripts stripped, stylesheets inlined,
//! site-relative URLs made absolute. Regions are then swapped through `Page`.

const std = @import("std");
const c = @import("lexbor");
const dom = @import("../html/dom.zig");
const Fetcher = @import("../net/Fetcher.zig");
const Classes = @import("Classes.zig");
const Node = dom.Node;
const Element = dom.Element;
const log = std.log.scoped(.chrome);

/// How long a fetched page stays fresh; stylesheets are content-hashed and kept forever.
pub const page_ttl = 6 * 60 * 60;

const site = "https://github.com";

pub const Page = struct {
    gpa: std.mem.Allocator,
    doc: *c.lxb_html_document_t,
    /// Raw HTML spliced in at serialization, keyed by the marker comment's text.
    splices: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// The inlined stylesheets, kept alive because `classes` points into them.
    css: std.ArrayList([]u8) = .empty,
    classes: Classes = .{},

    pub fn deinit(self: *Page) void {
        _ = c.lxb_html_document_destroy(self.doc);
        self.splices.deinit(self.gpa);
        self.classes.deinit(self.gpa);
        for (self.css.items) |s| self.gpa.free(s);
        self.css.deinit(self.gpa);
    }

    /// A hashed class from its stem, falling back to `fallback` (stable utility classes) when unresolvable.
    pub fn class(self: *const Page, stem: []const u8, fallback: []const u8) []const u8 {
        return self.classes.resolve(stem) orelse fallback;
    }

    pub fn root(self: *Page) *Node {
        return &self.doc.*.dom_document.node;
    }

    /// Replaces `target`'s children with `html`, which is trusted and inserted verbatim.
    pub fn setInnerHtml(self: *Page, target: *Node, key: []const u8, html: []const u8) !void {
        while (@as(?*Node, target.first_child)) |child| dom.remove(child);
        const marker = c.lxb_dom_document_create_comment(&self.doc.*.dom_document, key.ptr, key.len) orelse return error.OutOfMemory;
        c.lxb_dom_node_insert_child(target, @ptrCast(marker));
        try self.splices.put(self.gpa, key, html);
    }

    /// Replaces `target` itself with `html`, which is trusted and inserted verbatim.
    pub fn replaceWith(self: *Page, target: *Node, key: []const u8, html: []const u8) !void {
        const marker = c.lxb_dom_document_create_comment(&self.doc.*.dom_document, key.ptr, key.len) orelse return error.OutOfMemory;
        c.lxb_dom_node_insert_before(target, @ptrCast(marker));
        dom.remove(target);
        try self.splices.put(self.gpa, key, html);
    }

    pub fn serialize(self: *Page, gpa: std.mem.Allocator) ![]u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(gpa);
        try raw.appendSlice(gpa, "<!DOCTYPE html>\n");
        var child: ?*Node = self.root().first_child;
        while (child) |ch| : (child = ch.next) {
            if (ch.type == c.LXB_DOM_NODE_TYPE_DOCUMENT_TYPE) continue;
            try dom.serialize(gpa, ch, &raw);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var rest: []const u8 = raw.items;
        while (std.mem.indexOf(u8, rest, "<!--gp-")) |i| {
            const end = std.mem.indexOfPos(u8, rest, i, "-->") orelse break;
            const key = rest[i + 4 .. end];
            try out.appendSlice(gpa, rest[0..i]);
            if (self.splices.get(key)) |html| try out.appendSlice(gpa, html) else try out.appendSlice(gpa, rest[i .. end + 3]);
            rest = rest[end + 3 ..];
        }
        try out.appendSlice(gpa, rest);
        return out.toOwnedSlice(gpa);
    }
};

/// Fetches `url` and prepares it as a template.
pub fn load(gpa: std.mem.Allocator, fetcher: *Fetcher, url: []const u8) !Page {
    const res = try fetcher.get(.{ .url = url, .ttl = page_ttl, .accept = "text/html" });
    if (res.status.class() != .success) return error.TemplateUnavailable;
    defer gpa.free(res.body);
    return parse(gpa, fetcher, res.body);
}

/// Prepares already-fetched page HTML; `fetcher` supplies its stylesheets.
pub fn parse(gpa: std.mem.Allocator, fetcher: *Fetcher, html: []const u8) !Page {
    const doc = c.lxb_html_document_create() orelse return error.OutOfMemory;
    errdefer _ = c.lxb_html_document_destroy(doc);
    if (c.lxb_html_document_parse(doc, html.ptr, html.len) != c.LXB_STATUS_OK) return error.HtmlParse;

    var page: Page = .{ .gpa = gpa, .doc = doc };
    var prep: Prep = .{ .gpa = gpa, .fetcher = fetcher, .doc = doc, .page = &page };
    defer prep.seen.deinit(gpa);
    try dom.eachElement(page.root(), &prep, Prep.visit);
    for (page.css.items) |css| try page.classes.index(gpa, css);
    return page;
}

const Prep = struct {
    gpa: std.mem.Allocator,
    fetcher: *Fetcher,
    doc: *c.lxb_html_document_t,
    page: *Page,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn visit(self: *Prep, node: *Node) anyerror!void {
        const name = dom.localName(node);
        const el: *Element = @ptrCast(node);
        if (std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "noscript")) return dom.remove(node);
        if (std.mem.eql(u8, name, "link")) return self.link(node, el);
        inline for (.{ "href", "src", "action", "poster" }) |attr| {
            if (dom.getAttr(el, attr)) |v| {
                if (std.mem.startsWith(u8, v, "/") and !std.mem.startsWith(u8, v, "//")) {
                    const abs = try std.fmt.allocPrint(self.gpa, site ++ "{s}", .{v});
                    defer self.gpa.free(abs);
                    dom.setAttr(el, attr, abs);
                }
            }
        }
    }

    fn link(self: *Prep, node: *Node, el: *Element) !void {
        const rel = dom.getAttr(el, "rel") orelse return dom.remove(node);
        if (std.mem.indexOf(u8, rel, "icon") != null) return;
        if (!std.mem.eql(u8, rel, "stylesheet")) return dom.remove(node);
        const href = dom.getAttr(el, "href") orelse return dom.remove(node);
        if (self.seen.contains(href)) return dom.remove(node);
        const owned_href = try self.gpa.dupe(u8, href);
        try self.seen.put(self.gpa, owned_href, {});

        const res = self.fetcher.get(.{ .url = owned_href, .ttl = null, .accept = "text/css" }) catch |err| {
            log.warn("stylesheet {s} unavailable: {s}", .{ owned_href, @errorName(err) });
            return dom.remove(node);
        };
        if (res.status.class() != .success) return dom.remove(node);
        try self.page.css.append(self.gpa, res.body);

        const style: *Node = @ptrCast(c.lxb_dom_document_create_element(&self.doc.*.dom_document, "style", 5, null) orelse return error.OutOfMemory);
        if (dom.getAttr(el, "media")) |m| dom.setAttr(@ptrCast(style), "media", m);
        const text: *Node = @ptrCast(c.lxb_dom_document_create_text_node(&self.doc.*.dom_document, res.body.ptr, res.body.len) orelse return error.OutOfMemory);
        c.lxb_dom_node_insert_child(style, text);
        c.lxb_dom_node_insert_before(node, style);
        dom.remove(node);
    }
};

fn hasAttrValue(node: *Node, name: []const u8, value: []const u8) bool {
    if (node.type != c.LXB_DOM_NODE_TYPE_ELEMENT) return false;
    const v = dom.getAttr(@ptrCast(node), name) orelse return false;
    return std.mem.eql(u8, v, value);
}

/// The README body: `<article class="markdown-body ..." itemprop="text">`.
pub fn readmeArticle(page: *Page) ?*Node {
    return dom.find(page.root(), {}, struct {
        fn pred(_: void, n: *Node) bool {
            return std.mem.eql(u8, dom.localName(n), "article") and hasAttrValue(n, "itemprop", "text");
        }
    }.pred);
}

/// The element carrying `data-testid="<id>"`.
pub fn byTestId(page: *Page, id: []const u8) ?*Node {
    return dom.find(page.root(), id, struct {
        fn pred(want: []const u8, n: *Node) bool {
            return hasAttrValue(n, "data-testid", want);
        }
    }.pred);
}
