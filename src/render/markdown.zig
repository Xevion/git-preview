const std = @import("std");
const c = @import("cmark");

/// The GFM extensions GitHub enables on top of CommonMark.
const extensions = [_][:0]const u8{ "table", "strikethrough", "autolink", "tagfilter", "tasklist" };

/// Raw HTML is kept because GitHub sanitizes after rendering rather than refusing it outright.
const options: c_int = c.CMARK_OPT_UNSAFE | c.CMARK_OPT_FOOTNOTES | c.CMARK_OPT_GITHUB_PRE_LANG;

/// Renders GitHub-flavored Markdown to an HTML fragment owned by `gpa`.
pub fn toHtml(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    c.cmark_gfm_core_extensions_ensure_registered();

    const parser = c.cmark_parser_new(options) orelse return error.OutOfMemory;
    defer c.cmark_parser_free(parser);

    for (extensions) |name| {
        const ext = c.cmark_find_syntax_extension(name.ptr) orelse return error.MissingExtension;
        if (c.cmark_parser_attach_syntax_extension(parser, ext) == 0) return error.MissingExtension;
    }

    c.cmark_parser_feed(parser, source.ptr, source.len);
    const doc = c.cmark_parser_finish(parser) orelse return error.OutOfMemory;
    defer c.cmark_node_free(doc);

    const html = c.cmark_render_html(doc, options, c.cmark_parser_get_syntax_extensions(parser)) orelse
        return error.OutOfMemory;
    defer c.free(html);

    return gpa.dupe(u8, std.mem.span(html));
}

test "renders a GFM table and task list" {
    const gpa = std.testing.allocator;
    const html = try toHtml(gpa,
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\- [x] done
        \\
    );
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"checkbox\"") != null);
}
