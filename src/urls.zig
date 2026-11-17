//! Resolves a document's relative URLs: images are inlined as data URIs, links point at the forge.

const std = @import("std");
const Source = @import("source.zig").Source;
const filter = @import("html/filter.zig");

pub const Resolver = struct {
    /// Owns every returned URL; they must outlive the render.
    arena: std.mem.Allocator,
    io: std.Io,
    source: Source,
    /// Repo-relative directory of the document being rendered ("" for the root).
    doc_dir: []const u8,
    /// Prefix that turns a repo path into a forge blob URL, e.g. `https://github.com/o/r/blob/HEAD/`.
    blob_base: ?[]const u8,

    pub fn rewriter(self: *Resolver) filter.UrlRewriter {
        return .{ .ctx = self, .imageFn = image, .linkFn = link };
    }

    fn image(ctx: *anyopaque, url: []const u8) anyerror![]const u8 {
        const self: *Resolver = @ptrCast(@alignCast(ctx));
        const target = try self.repoPath(url) orelse return url;
        const mime = mimeType(target.path) orelse return url;
        const bytes = try self.source.read(self.arena, self.io, target.path) orelse {
            std.log.warn("image not found in repository: {s}", .{target.path});
            return url;
        };
        const enc = std.base64.standard.Encoder;
        const prefix = try std.fmt.allocPrint(self.arena, "data:{s};base64,", .{mime});
        const out = try self.arena.alloc(u8, prefix.len + enc.calcSize(bytes.len));
        @memcpy(out[0..prefix.len], prefix);
        _ = enc.encode(out[prefix.len..], bytes);
        return out;
    }

    fn link(ctx: *anyopaque, url: []const u8) anyerror![]const u8 {
        const self: *Resolver = @ptrCast(@alignCast(ctx));
        const base = self.blob_base orelse return url;
        const target = try self.repoPath(url) orelse return url;
        return std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ base, target.path, target.suffix });
    }

    const Target = struct { path: []const u8, suffix: []const u8 };

    /// Maps a relative URL to a normalized repo path; null for absolute URLs, anchors, and escapes above the root.
    fn repoPath(self: *Resolver, url: []const u8) !?Target {
        if (url.len == 0 or url[0] == '#' or std.mem.startsWith(u8, url, "//")) return null;
        if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
            if (std.mem.indexOfAny(u8, url[0..colon], "/?#") == null) return null;
        }
        const cut = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
        const decoded = try percentDecode(self.arena, url[0..cut]);
        const rooted = decoded.len > 0 and decoded[0] == '/';
        const path = (try normalize(self.arena, if (rooted) "" else self.doc_dir, decoded)) orelse return null;
        return .{ .path = path, .suffix = url[cut..] };
    }
};

fn percentDecode(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = s[i];
        i += 1;
    }
    return out[0..n];
}

/// Joins and collapses `.`/`..`; null if the path climbs above the repository root.
fn normalize(gpa: std.mem.Allocator, dir: []const u8, rel: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    inline for (.{ dir, rel }) |piece| {
        var it = std.mem.tokenizeScalar(u8, piece, '/');
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len == 0) return null;
                _ = parts.pop();
                continue;
            }
            try parts.append(gpa, seg);
        }
    }
    if (parts.items.len == 0) return null;
    return try std.mem.join(gpa, "/", parts.items);
}

fn mimeType(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".png", "image/png" },   .{ ".jpg", "image/jpeg" },    .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },   .{ ".svg", "image/svg+xml" }, .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" }, .{ ".ico", "image/x-icon" },  .{ ".bmp", "image/bmp" },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return null;
}

test "relative URLs resolve against the document's directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/img");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/img/a b.png", .data = "PNG" });

    var r: Resolver = .{
        .arena = arena,
        .io = io,
        .source = .{ .worktree = tmp.dir },
        .doc_dir = "docs",
        .blob_base = "https://github.com/o/r/blob/HEAD/",
    };
    const rw = r.rewriter();
    try std.testing.expectEqualStrings("data:image/png;base64,UE5H", try rw.image("img/a%20b.png"));
    try std.testing.expectEqualStrings("https://example.com/x.png", try rw.image("https://example.com/x.png"));
    try std.testing.expectEqualStrings("missing.png", try rw.image("missing.png"));
    try std.testing.expectEqualStrings("https://github.com/o/r/blob/HEAD/README.md#usage", try rw.link("../README.md#usage"));
    try std.testing.expectEqualStrings("https://github.com/o/r/blob/HEAD/LICENSE", try rw.link("/LICENSE"));
    try std.testing.expectEqualStrings("#anchor", try rw.link("#anchor"));
    try std.testing.expectEqualStrings("../../escape", try rw.link("../../escape"));
}
