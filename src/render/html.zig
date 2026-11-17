//! Renders a cmark-gfm AST into the markup GitHub serves for a README view.

const std = @import("std");
const c = @import("cmark");
const octicons = @import("octicons.zig");
const sanitize = @import("sanitize.zig");
const Slugger = @import("slug.zig").Slugger;
const Writer = std.Io.Writer;
const Node = c.cmark_node;

pub const Options = struct {
    /// `.hard` mimics comment rendering (and the `/markdown` gfm API mode used for goldens).
    soft_break: enum { newline, hard } = .newline,
    /// README views wrap headings with permalink anchors; the `/markdown` API does not.
    heading_anchors: bool = true,
    /// Links to this host stay followable; every other absolute link gets `rel="nofollow"`.
    own_host: []const u8 = "github.com",
    /// Suffix that keeps footnote ids unique when several documents share a page.
    footnote_suffix: []const u8 = "",
    rewriter: sanitize.UrlRewriter = .identity,
};

pub fn render(gpa: std.mem.Allocator, w: *Writer, doc: *Node, options: Options) !void {
    var r: Renderer = .{
        .gpa = gpa,
        .w = w,
        .opts = options,
        .slugger = .init(gpa),
        .raw = .{ .rewriter = options.rewriter },
    };
    defer r.slugger.deinit();
    try r.children(doc);
    if (r.footnote_count > 0) try w.writeAll("</ol>\n</section>\n");
}

const Renderer = struct {
    gpa: std.mem.Allocator,
    w: *Writer,
    opts: Options,
    slugger: Slugger,
    raw: sanitize.State,
    footnote_count: u32 = 0,
    /// Mirrors cmark's `cr()`: tracks whether output currently ends in a newline.
    at_line_start: bool = true,

    fn out(r: *Renderer, s: []const u8) !void {
        if (s.len == 0) return;
        try r.w.writeAll(s);
        r.at_line_start = s[s.len - 1] == '\n';
    }

    fn print(r: *Renderer, comptime fmt: []const u8, args: anytype) !void {
        var buf: [512]u8 = undefined;
        try r.out(try std.fmt.bufPrint(&buf, fmt, args));
    }

    fn cr(r: *Renderer) !void {
        if (!r.at_line_start) try r.out("\n");
    }

    fn children(r: *Renderer, parent: *Node) anyerror!void {
        var child = c.cmark_node_first_child(parent);
        while (child) |ch| : (child = c.cmark_node_next(ch)) try r.node(ch);
    }

    fn node(r: *Renderer, n: *Node) anyerror!void {
        const ty = c.cmark_node_get_type(n);
        switch (ty) {
            c.CMARK_NODE_DOCUMENT => try r.children(n),
            c.CMARK_NODE_PARAGRAPH => try r.paragraph(n),
            c.CMARK_NODE_HEADING => try r.heading(n),
            c.CMARK_NODE_BLOCK_QUOTE => try r.blockquote(n),
            c.CMARK_NODE_LIST => try r.list(n),
            c.CMARK_NODE_ITEM => try r.item(n),
            c.CMARK_NODE_CODE_BLOCK => try r.codeBlock(n),
            c.CMARK_NODE_HTML_BLOCK => {
                try r.cr();
                try r.rawHtml(literal(n));
                try r.cr();
            },
            c.CMARK_NODE_THEMATIC_BREAK => {
                try r.cr();
                try r.out("<hr>\n");
            },
            c.CMARK_NODE_FOOTNOTE_DEFINITION => try r.footnoteDef(n),
            c.CMARK_NODE_TEXT => try r.text(literal(n)),
            c.CMARK_NODE_SOFTBREAK => try r.out(if (r.opts.soft_break == .hard) "<br>\n" else "\n"),
            c.CMARK_NODE_LINEBREAK => try r.out("<br>\n"),
            c.CMARK_NODE_CODE => {
                try r.out("<code class=\"notranslate\">");
                try r.text(literal(n));
                try r.out("</code>");
            },
            c.CMARK_NODE_HTML_INLINE => try r.rawHtml(literal(n)),
            c.CMARK_NODE_EMPH => try r.wrap(n, "<em>", "</em>"),
            c.CMARK_NODE_STRONG => try r.wrap(n, "<strong>", "</strong>"),
            c.CMARK_NODE_LINK => try r.link(n),
            c.CMARK_NODE_IMAGE => try r.image(n),
            c.CMARK_NODE_FOOTNOTE_REFERENCE => try r.footnoteRef(n),
            else => try r.extensionNode(n),
        }
    }

    fn extensionNode(r: *Renderer, n: *Node) !void {
        const kind = std.mem.span(c.cmark_node_get_type_string(n));
        if (std.mem.eql(u8, kind, "strikethrough")) {
            try r.wrap(n, "<del>", "</del>");
        } else if (std.mem.eql(u8, kind, "table")) {
            try r.table(n);
        } else {
            try r.children(n);
        }
    }

    fn wrap(r: *Renderer, n: *Node, open: []const u8, close: []const u8) !void {
        try r.out(open);
        try r.children(n);
        try r.out(close);
    }

    fn rawHtml(r: *Renderer, src: []const u8) !void {
        try sanitize.sanitize(&r.raw, r.w, src);
        if (src.len > 0) r.at_line_start = src[src.len - 1] == '\n';
    }

    fn text(r: *Renderer, s: []const u8) !void {
        var start: usize = 0;
        for (s, 0..) |ch, i| {
            const rep: []const u8 = switch (ch) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => continue,
            };
            try r.out(s[start..i]);
            try r.out(rep);
            start = i + 1;
        }
        try r.out(s[start..]);
    }

    fn attr(r: *Renderer, s: []const u8) !void {
        var start: usize = 0;
        for (s, 0..) |ch, i| {
            const rep: []const u8 = switch (ch) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            try r.out(s[start..i]);
            try r.out(rep);
            start = i + 1;
        }
        try r.out(s[start..]);
    }

    fn inTightList(n: *Node) bool {
        const li = c.cmark_node_parent(n) orelse return false;
        if (c.cmark_node_get_type(li) != c.CMARK_NODE_ITEM) return false;
        const lst = c.cmark_node_parent(li) orelse return false;
        return c.cmark_node_get_list_tight(lst) != 0;
    }

    fn paragraph(r: *Renderer, n: *Node) !void {
        const tight = inTightList(n);
        if (!tight) {
            try r.cr();
            try r.out("<p dir=\"auto\">");
        }
        try r.children(n);
        const parent = c.cmark_node_parent(n).?;
        if (c.cmark_node_get_type(parent) == c.CMARK_NODE_FOOTNOTE_DEFINITION and c.cmark_node_next(n) == null) {
            try r.out(" ");
            try r.footnoteBackrefs(parent);
        }
        if (!tight) try r.out("</p>\n");
    }

    fn heading(r: *Renderer, n: *Node) !void {
        const level = c.cmark_node_get_heading_level(n);
        try r.cr();
        if (!r.opts.heading_anchors) {
            try r.print("<h{d} dir=\"auto\">", .{level});
            try r.children(n);
            try r.print("</h{d}>\n", .{level});
            return;
        }
        const plain = try plainText(r.gpa, n);
        defer r.gpa.free(plain);
        const slug = try r.slugger.slug(plain);
        try r.print("<div class=\"markdown-heading\" dir=\"auto\"><h{d} class=\"heading-element\" dir=\"auto\">", .{level});
        try r.children(n);
        try r.print("</h{d}><a id=\"user-content-", .{level});
        try r.attr(slug);
        try r.out("\" class=\"anchor\" aria-label=\"Permalink: ");
        try r.attr(plain);
        try r.out("\" href=\"#");
        try r.attr(slug);
        try r.out("\">");
        try r.octicon("octicon-link", octicons.link);
        try r.out("</a></div>\n");
    }

    fn octicon(r: *Renderer, class: []const u8, body: []const u8) !void {
        try r.print("<svg data-component=\"Octicon\" class=\"octicon {s}\" viewBox=\"0 0 16 16\" version=\"1.1\" width=\"16\" height=\"16\" aria-hidden=\"true\">", .{class});
        try r.out(body);
        try r.out("</svg>");
    }

    const Alert = struct { class: []const u8, title: []const u8, icon: []const u8, svg: []const u8 };

    const alerts = [_]Alert{
        .{ .class = "note", .title = "Note", .icon = "octicon-info mr-2", .svg = octicons.info },
        .{ .class = "tip", .title = "Tip", .icon = "octicon-light-bulb mr-2", .svg = octicons.light_bulb },
        .{ .class = "important", .title = "Important", .icon = "octicon-report mr-2", .svg = octicons.report },
        .{ .class = "warning", .title = "Warning", .icon = "octicon-alert mr-2", .svg = octicons.alert },
        .{ .class = "caution", .title = "Caution", .icon = "octicon-stop mr-2", .svg = octicons.stop },
    };

    /// Detects `[!TYPE]` alone on a blockquote's first line, followed by more content.
    fn alertMarker(quote: *Node) ?struct { alert: Alert, marker: *Node, brk: ?*Node } {
        const para = c.cmark_node_first_child(quote) orelse return null;
        if (c.cmark_node_get_type(para) != c.CMARK_NODE_PARAGRAPH) return null;
        const first = c.cmark_node_first_child(para) orelse return null;
        if (c.cmark_node_get_type(first) != c.CMARK_NODE_TEXT) return null;
        const lit = literal(first);
        if (lit.len < 4 or !std.mem.startsWith(u8, lit, "[!") or lit[lit.len - 1] != ']') return null;
        const name = lit[2 .. lit.len - 1];
        const after = c.cmark_node_next(first);
        if (after) |a| {
            if (c.cmark_node_get_type(a) != c.CMARK_NODE_SOFTBREAK and c.cmark_node_get_type(a) != c.CMARK_NODE_LINEBREAK) return null;
        } else if (c.cmark_node_next(para) == null) {
            return null;
        }
        for (alerts) |a| {
            if (std.ascii.eqlIgnoreCase(a.class, name)) return .{ .alert = a, .marker = first, .brk = after };
        }
        return null;
    }

    fn blockquote(r: *Renderer, n: *Node) !void {
        try r.cr();
        const found = alertMarker(n) orelse {
            try r.out("<blockquote>\n");
            try r.children(n);
            try r.cr();
            try r.out("</blockquote>\n");
            return;
        };
        try r.print("<div class=\"markdown-alert markdown-alert-{s}\" dir=\"auto\"><p class=\"markdown-alert-title\" dir=\"auto\">", .{found.alert.class});
        try r.octicon(found.alert.icon, found.alert.svg);
        try r.print("{s}</p>", .{found.alert.title});
        r.at_line_start = true;
        const para = c.cmark_node_first_child(n).?;
        c.cmark_node_free(found.marker);
        if (found.brk) |b| c.cmark_node_free(b);
        if (c.cmark_node_first_child(para) == null) c.cmark_node_free(para);
        try r.children(n);
        try r.cr();
        try r.out("</div>\n");
    }

    fn list(r: *Renderer, n: *Node) !void {
        try r.cr();
        const tasks = hasTaskItems(n);
        const attrs: []const u8 = if (tasks) " class=\"contains-task-list\"" else " dir=\"auto\"";
        if (c.cmark_node_get_list_type(n) == c.CMARK_BULLET_LIST) {
            try r.print("<ul{s}>\n", .{attrs});
            try r.children(n);
            try r.out("</ul>\n");
        } else {
            const start = c.cmark_node_get_list_start(n);
            if (start != 1) try r.print("<ol start=\"{d}\"{s}>\n", .{ start, attrs }) else try r.print("<ol{s}>\n", .{attrs});
            try r.children(n);
            try r.out("</ol>\n");
        }
    }

    fn hasTaskItems(lst: *Node) bool {
        var child = c.cmark_node_first_child(lst);
        while (child) |ch| : (child = c.cmark_node_next(ch)) {
            if (isTaskItem(ch)) return true;
        }
        return false;
    }

    fn isTaskItem(n: *Node) bool {
        return std.mem.eql(u8, std.mem.span(c.cmark_node_get_type_string(n)), "tasklist");
    }

    fn item(r: *Renderer, n: *Node) !void {
        try r.cr();
        if (isTaskItem(n)) {
            const checked = c.cmark_gfm_extensions_get_tasklist_item_checked(n);
            try r.out("<li class=\"task-list-item\"><input type=\"checkbox\" id=\"\" disabled=\"\" class=\"task-list-item-checkbox\"");
            try r.out(if (checked) " aria-label=\"Completed task\" checked=\"\"> " else " aria-label=\"Incomplete task\"> ");
        } else {
            try r.out("<li>");
        }
        try r.children(n);
        try r.out("</li>\n");
    }

    fn codeBlock(r: *Renderer, n: *Node) !void {
        try r.cr();
        const info = std.mem.span(c.cmark_node_get_fence_info(n));
        const lang_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
        const lang = info[0..lang_end];
        if (lang.len > 0) {
            try r.out("<pre lang=\"");
            try r.attr(lang);
            try r.out("\" class=\"notranslate\">");
        } else {
            try r.out("<pre class=\"notranslate\">");
        }
        try r.out("<code class=\"notranslate\">");
        try r.text(literal(n));
        try r.out("</code></pre>\n");
    }

    fn isExternal(r: *Renderer, url: []const u8) bool {
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
        const rest = url[scheme_end + 3 ..];
        const host_end = std.mem.indexOfAny(u8, rest, "/:?#") orelse rest.len;
        return !std.ascii.eqlIgnoreCase(rest[0..host_end], r.opts.own_host);
    }

    fn link(r: *Renderer, n: *Node) !void {
        const url = std.mem.span(c.cmark_node_get_url(n));
        const title = std.mem.span(c.cmark_node_get_title(n));
        try r.out("<a");
        if (sanitize.safeUrl(url)) {
            try r.out(" href=\"");
            try r.href(try r.opts.rewriter.link(url));
            try r.out("\"");
        }
        if (title.len > 0) {
            try r.out(" title=\"");
            try r.attr(title);
            try r.out("\"");
        }
        if (r.isExternal(url)) try r.out(" rel=\"nofollow\"");
        try r.out(">");
        r.raw.link_depth += 1;
        try r.children(n);
        r.raw.link_depth -= 1;
        try r.out("</a>");
    }

    fn image(r: *Renderer, n: *Node) !void {
        const url = std.mem.span(c.cmark_node_get_url(n));
        const title = std.mem.span(c.cmark_node_get_title(n));
        const alt = try plainText(r.gpa, n);
        defer r.gpa.free(alt);
        const safe = sanitize.safeUrl(url);
        const src = if (safe) try r.opts.rewriter.image(url) else "";
        const external = r.isExternal(url);
        const wrap_link = r.raw.link_depth == 0 and safe;
        if (wrap_link) {
            try r.out(if (external) "<a target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"" else "<a target=\"_blank\" rel=\"noopener noreferrer\" href=\"");
            try r.href(src);
            try r.out("\">");
        }
        try r.out("<img");
        if (safe) {
            try r.out(" src=\"");
            try r.href(src);
            try r.out("\"");
        }
        try r.out(" alt=\"");
        try r.attr(alt);
        try r.out("\"");
        if (title.len > 0) {
            try r.out(" title=\"");
            try r.attr(title);
            try r.out("\"");
        }
        if (external) {
            try r.out(" data-canonical-src=\"");
            try r.href(url);
            try r.out("\"");
        }
        try r.out(" style=\"max-width: 100%;\">");
        if (wrap_link) try r.out("</a>");
    }

    /// Percent-encodes what cmark's href escaper does; `data:` URIs pass through untouched.
    fn href(r: *Renderer, url: []const u8) !void {
        if (std.mem.startsWith(u8, url, "data:")) return r.out(url);
        const safe_chars = "-_.+!*'(),%#@?=;:/,$~";
        var start: usize = 0;
        for (url, 0..) |ch, i| {
            if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, safe_chars, ch) != null) continue;
            try r.out(url[start..i]);
            if (ch == '&') try r.out("&amp;") else try r.print("%{X:0>2}", .{ch});
            start = i + 1;
        }
        try r.out(url[start..]);
    }

    fn footnoteLabel(def: *Node) []const u8 {
        return def.as.literal.data[0..@intCast(def.as.literal.len)];
    }

    fn footnoteRef(r: *Renderer, n: *Node) !void {
        const def = n.parent_footnote_def orelse return;
        const label = footnoteLabel(def);
        try r.out("<sup><a href=\"#user-content-fn-");
        try r.href(label);
        try r.print("{s}\" id=\"user-content-fnref-", .{r.opts.footnote_suffix});
        try r.href(label);
        if (n.footnote.ref_ix > 1) try r.print("-{d}", .{n.footnote.ref_ix});
        try r.print("{s}\" data-footnote-ref=\"\" aria-describedby=\"footnote-label\">", .{r.opts.footnote_suffix});
        try r.text(literal(n));
        try r.out("</a></sup>");
    }

    fn footnoteDef(r: *Renderer, n: *Node) !void {
        try r.cr();
        if (r.footnote_count == 0) {
            try r.out("<section data-footnotes=\"\" class=\"footnotes\"><h2 id=\"footnote-label\" class=\"sr-only\" dir=\"auto\">Footnotes</h2>\n<ol dir=\"auto\">\n");
        }
        r.footnote_count += 1;
        try r.out("<li id=\"user-content-fn-");
        try r.href(footnoteLabel(n));
        try r.print("{s}\">\n", .{r.opts.footnote_suffix});
        try r.children(n);
        const last = c.cmark_node_last_child(n);
        if (last == null or c.cmark_node_get_type(last.?) != c.CMARK_NODE_PARAGRAPH) {
            try r.footnoteBackrefs(n);
            try r.out("\n");
        }
        try r.cr();
        try r.out("</li>\n");
    }

    fn footnoteBackrefs(r: *Renderer, def: *Node) !void {
        const label = footnoteLabel(def);
        const count: u32 = @intCast(@max(def.footnote.def_count, 1));
        const ix = r.footnote_count;
        var i: u32 = 1;
        while (i <= count) : (i += 1) {
            if (i > 1) try r.out(" ");
            try r.out("<a href=\"#user-content-fnref-");
            try r.href(label);
            if (i > 1) try r.print("-{d}", .{i});
            try r.print("{s}\" data-footnote-backref=\"\" aria-label=\"Back to reference {d}", .{ r.opts.footnote_suffix, ix });
            if (i > 1) try r.print("-{d}", .{i});
            try r.out("\" class=\"data-footnote-backref\">\u{21a9}");
            if (i > 1) try r.print("<sup>{d}</sup>", .{i});
            try r.out("</a>");
        }
    }

    fn table(r: *Renderer, n: *Node) !void {
        try r.cr();
        try r.out("<markdown-accessiblity-table><table role=\"table\">\n");
        const aligns = c.cmark_gfm_extensions_get_table_alignments(n);
        var in_body = false;
        var row = c.cmark_node_first_child(n);
        while (row) |rw| : (row = c.cmark_node_next(rw)) {
            const header = c.cmark_gfm_extensions_get_table_row_is_header(rw) != 0;
            if (header) {
                try r.out("<thead>\n");
            } else if (!in_body) {
                try r.out("<tbody>\n");
                in_body = true;
            }
            try r.out("<tr>\n");
            const cell_tag: []const u8 = if (header) "th" else "td";
            var col: usize = 0;
            var cell = c.cmark_node_first_child(rw);
            while (cell) |cl| : ({
                cell = c.cmark_node_next(cl);
                col += 1;
            }) {
                const alignment: []const u8 = switch (aligns[col]) {
                    'l' => " align=\"left\"",
                    'c' => " align=\"center\"",
                    'r' => " align=\"right\"",
                    else => "",
                };
                try r.print("<{s}{s}>", .{ cell_tag, alignment });
                try r.children(cl);
                try r.print("</{s}>\n", .{cell_tag});
            }
            try r.out("</tr>\n");
            if (header) try r.out("</thead>\n");
        }
        if (in_body) try r.out("</tbody>\n");
        try r.out("</table></markdown-accessiblity-table>\n");
    }
};

fn literal(n: *Node) []const u8 {
    const ptr = c.cmark_node_get_literal(n) orelse return "";
    return std.mem.span(ptr);
}

/// Concatenated text content, as used for heading slugs and image alt text.
fn plainText(gpa: std.mem.Allocator, n: *Node) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try collectText(gpa, &buf, n);
    return buf.toOwnedSlice(gpa);
}

fn collectText(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), n: *Node) !void {
    var child = c.cmark_node_first_child(n);
    while (child) |ch| : (child = c.cmark_node_next(ch)) {
        switch (c.cmark_node_get_type(ch)) {
            c.CMARK_NODE_TEXT, c.CMARK_NODE_CODE => try buf.appendSlice(gpa, literal(ch)),
            c.CMARK_NODE_SOFTBREAK, c.CMARK_NODE_LINEBREAK => try buf.append(gpa, ' '),
            else => try collectText(gpa, buf, ch),
        }
    }
}
