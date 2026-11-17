//! Where file contents come from: the working tree as it is on disk, or a committed revision.

const std = @import("std");
const Repo = @import("repo/Repo.zig");
const Io = std.Io;

pub const Source = union(enum) {
    worktree: Io.Dir,
    commit: struct { repo: *const Repo, oid: Repo.Oid },

    /// Reads a repo-relative path; returns null when it does not exist.
    pub fn read(self: Source, gpa: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
        return switch (self) {
            .worktree => |dir| dir.readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
                error.FileNotFound, error.IsDir, error.NotDir => null,
                else => err,
            },
            .commit => |cm| cm.repo.readPath(gpa, io, cm.oid, path) catch |err| switch (err) {
                error.PathNotFound, error.IsDir, error.NotDir, error.IsSubmodule => null,
                else => err,
            },
        };
    }

    /// Names of the regular files directly inside a repo-relative directory ("" is the root).
    pub fn listFiles(self: Source, gpa: std.mem.Allocator, io: Io, dir_path: []const u8) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        switch (self) {
            .worktree => |root| {
                var dir = (if (dir_path.len == 0) root.openDir(io, ".", .{ .iterate = true }) else root.openDir(io, dir_path, .{ .iterate = true })) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => return names.toOwnedSlice(gpa),
                    else => return err,
                };
                defer dir.close(io);
                var it = dir.iterate();
                while (try it.next(io)) |entry| {
                    if (entry.kind == .file or entry.kind == .sym_link) try names.append(gpa, try gpa.dupe(u8, entry.name));
                }
            },
            .commit => |cm| {
                const entries = cm.repo.listTree(gpa, io, cm.oid, dir_path) catch |err| switch (err) {
                    error.PathNotFound, error.NotDir => return names.toOwnedSlice(gpa),
                    else => return err,
                };
                defer Repo.freeEntries(gpa, entries);
                for (entries) |e| {
                    if (e.kind == .file or e.kind == .executable or e.kind == .symlink) try names.append(gpa, try gpa.dupe(u8, e.name));
                }
            },
        }
        return names.toOwnedSlice(gpa);
    }
};

pub const max_file_size = 64 << 20;

const readme_dirs = [_][]const u8{ ".github", "", "docs" };
const markdown_exts = [_][]const u8{ ".md", ".markdown", ".mdown", ".mkdn", ".mkd", ".mdwn" };

pub fn isMarkdown(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (markdown_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Finds the README GitHub would show: `.github/`, then the root, then `docs/`, Markdown only.
pub fn findReadme(gpa: std.mem.Allocator, io: Io, source: Source) !?[]u8 {
    for (readme_dirs) |dir| {
        const names = try source.listFiles(gpa, io, dir);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        std.mem.sort([]u8, names, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names) |n| {
            const stem = n[0 .. n.len - std.fs.path.extension(n).len];
            if (std.ascii.eqlIgnoreCase(stem, "readme") and isMarkdown(n)) {
                return if (dir.len == 0) try gpa.dupe(u8, n) else try std.fs.path.join(gpa, &.{ dir, n });
            }
        }
    }
    return null;
}

test "README lookup prefers .github, then the root, then docs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/README.md", .data = "d" });
    const src: Source = .{ .worktree = tmp.dir };

    const first = (try findReadme(gpa, io, src)).?;
    defer gpa.free(first);
    try std.testing.expectEqualStrings("docs/README.md", first);

    try tmp.dir.writeFile(io, .{ .sub_path = "readme.markdown", .data = "r" });
    const second = (try findReadme(gpa, io, src)).?;
    defer gpa.free(second);
    try std.testing.expectEqualStrings("readme.markdown", second);
}
