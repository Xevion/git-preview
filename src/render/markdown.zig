const std = @import("std");
const c = @import("cmark");
const html = @import("html.zig");
const filter = @import("../html/filter.zig");

pub const Options = html.Options;

/// The GFM extensions GitHub enables on top of CommonMark.
const extensions = [_][:0]const u8{ "table", "strikethrough", "autolink", "tagfilter", "tasklist" };

/// Raw HTML is kept because GitHub sanitizes after rendering rather than refusing it outright.
const parse_options: c_int = c.CMARK_OPT_UNSAFE | c.CMARK_OPT_FOOTNOTES | c.CMARK_OPT_GITHUB_PRE_LANG;

/// Renders GitHub-flavored Markdown to an HTML fragment owned by `gpa`.
pub fn toHtml(gpa: std.mem.Allocator, source: []const u8, options: Options) ![]u8 {
    c.cmark_gfm_core_extensions_ensure_registered();

    const parser = c.cmark_parser_new(parse_options) orelse return error.OutOfMemory;
    defer c.cmark_parser_free(parser);

    for (extensions) |name| {
        const ext = c.cmark_find_syntax_extension(name.ptr) orelse return error.MissingExtension;
        if (c.cmark_parser_attach_syntax_extension(parser, ext) == 0) return error.MissingExtension;
    }

    c.cmark_parser_feed(parser, source.ptr, source.len);
    const doc = c.cmark_parser_finish(parser) orelse return error.OutOfMemory;
    defer c.cmark_node_free(doc);

    // Derived from the source, so a document cannot contain the marker it would need to forge.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const nonce = std.fmt.bytesToHex(digest[0..8], .lower);
    var render_opts = options;
    render_opts.raw_nonce = &nonce;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try html.render(gpa, &out.writer, doc, render_opts);
    return filter.finalize(gpa, out.written(), .{
        .nonce = &nonce,
        .own_host = options.own_host,
        .rewriter = options.rewriter,
    });
}

/// Strips what legitimately differs from GitHub's output: footnote hash suffixes and camo image proxying.
fn normalizeGolden(gpa: std.mem.Allocator, golden: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const camo = "https://camo.githubusercontent.com/";
    var i: usize = 0;
    while (i < golden.len) {
        if (golden[i] == '-' and i + 33 < golden.len and golden[i + 33] == '"' and isHex(golden[i + 1 .. i + 33])) {
            i += 33;
            continue;
        }
        if (std.mem.startsWith(u8, golden[i..], camo)) {
            const rest = golden[i + camo.len ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/').?;
            const end = std.mem.indexOfScalar(u8, rest, '"').?;
            const encoded = rest[slash + 1 .. end];
            const decoded = try out.addManyAsSlice(gpa, encoded.len / 2);
            _ = try std.fmt.hexToBytes(decoded, encoded);
            i += camo.len + end;
            continue;
        }
        try out.append(gpa, golden[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn isHex(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    return true;
}

test "matches GitHub's recorded output for each fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fixtures = [_][]const u8{ "basics", "blocks", "alerts", "emoji" };
    for (fixtures) |name| {
        const md_path = try std.fmt.allocPrint(gpa, "tests/markdown/{s}.md", .{name});
        defer gpa.free(md_path);
        const golden_path = try std.fmt.allocPrint(gpa, "tests/markdown/{s}.github.html", .{name});
        defer gpa.free(golden_path);

        const source = try std.Io.Dir.cwd().readFileAlloc(io, md_path, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const golden_raw = try std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa, .limited(1 << 20));
        defer gpa.free(golden_raw);
        const golden = try normalizeGolden(gpa, golden_raw);
        defer gpa.free(golden);

        const got = try toHtml(gpa, source, .{ .view = .api });
        defer gpa.free(got);
        std.testing.expectEqualStrings(std.mem.trimEnd(u8, golden, "\n"), std.mem.trimEnd(u8, got, "\n")) catch |err| {
            std.debug.print("fixture {s} differs from GitHub\n", .{name});
            return err;
        };
    }
}

test "matches GitHub's README view for a recorded README" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "tests/readme/cmark-gfm.md", gpa, .limited(1 << 20));
    defer gpa.free(source);
    const page_raw = try std.Io.Dir.cwd().readFileAlloc(io, "tests/readme/cmark-gfm.github.html", gpa, .limited(1 << 20));
    defer gpa.free(page_raw);

    const open = "itemprop=\"text\">";
    const body_start = std.mem.indexOf(u8, page_raw, open).? + open.len;
    const body_end = std.mem.lastIndexOf(u8, page_raw, "</article>").?;
    const golden = try normalizeGolden(gpa, page_raw[body_start..body_end]);
    defer gpa.free(golden);

    const got = try toHtml(gpa, source, .{});
    defer gpa.free(got);
    try std.testing.expectEqualStrings(std.mem.trim(u8, golden, "\n"), std.mem.trim(u8, got, "\n"));
}
