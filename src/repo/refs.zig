//! Ref name validation and `packed-refs` parsing.

const std = @import("std");
const Oid = @import("odb.zig").Oid;

pub const Packed = struct {
    oid: Oid,
    /// Target of the `^` line following an annotated tag, fully peeled.
    peeled: ?Oid,
};

/// Finds `name` in the text of a `packed-refs` file.
pub fn findPacked(text: []const u8, name: []const u8) ?Packed {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < Oid.hex_len + 2 or line[0] == '#' or line[0] == '^') continue;
        if (line[Oid.hex_len] != ' ') continue;
        if (!std.mem.eql(u8, line[Oid.hex_len + 1 ..], name)) continue;
        const oid = Oid.parseHex(line[0..Oid.hex_len]) catch return null;
        var peeled: ?Oid = null;
        if (lines.peek()) |next| {
            const n = std.mem.trimEnd(u8, next, "\r");
            if (n.len == Oid.hex_len + 1 and n[0] == '^') peeled = Oid.parseHex(n[1..]) catch null;
        }
        return .{ .oid = oid, .peeled = peeled };
    }
    return null;
}

/// Rejects names that could escape the git directory or are not valid ref paths.
pub fn isSafeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or name[name.len - 1] == '/') return false;
    if (std.mem.indexOfAny(u8, name, "\x00\\") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    }
    return true;
}

/// Refs that live in the per-worktree git dir rather than the shared one.
pub fn isPerWorktree(name: []const u8) bool {
    return !std.mem.startsWith(u8, name, "refs/") or
        std.mem.startsWith(u8, name, "refs/bisect/") or
        std.mem.startsWith(u8, name, "refs/worktree/") or
        std.mem.startsWith(u8, name, "refs/rewritten/");
}

/// Names like `HEAD` or `ORIG_HEAD` that git looks up directly in the git dir.
pub fn isPseudoRef(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isUpper(c) or c == '_')) return false;
    return true;
}

const testing = std.testing;

test "findPacked with peeled lines" {
    const text =
        "# pack-refs with: peeled fully-peeled sorted \n" ++
        "1111111111111111111111111111111111111111 refs/heads/main\n" ++
        "2222222222222222222222222222222222222222 refs/tags/v1\n" ++
        "^3333333333333333333333333333333333333333\n" ++
        "4444444444444444444444444444444444444444 refs/tags/v2\r\n";
    const main = findPacked(text, "refs/heads/main").?;
    try testing.expectEqual(@as(?Oid, null), main.peeled);
    try testing.expectEqual(@as(u8, 0x11), main.oid.bytes[0]);

    const v1 = findPacked(text, "refs/tags/v1").?;
    try testing.expectEqual(@as(u8, 0x22), v1.oid.bytes[0]);
    try testing.expectEqual(@as(u8, 0x33), v1.peeled.?.bytes[0]);

    const v2 = findPacked(text, "refs/tags/v2").?;
    try testing.expectEqual(@as(?Oid, null), v2.peeled);

    try testing.expectEqual(@as(?Packed, null), findPacked(text, "refs/heads/ma"));
    try testing.expectEqual(@as(?Packed, null), findPacked(text, "refs/tags/v"));
}

test "name safety" {
    try testing.expect(isSafeName("refs/heads/feature/x"));
    try testing.expect(isSafeName("HEAD"));
    try testing.expect(!isSafeName("../config"));
    try testing.expect(!isSafeName("refs//x"));
    try testing.expect(!isSafeName("/etc/passwd"));
    try testing.expect(!isSafeName("a\\b"));
    try testing.expect(isPseudoRef("ORIG_HEAD"));
    try testing.expect(!isPseudoRef("main"));
    try testing.expect(isPerWorktree("HEAD"));
    try testing.expect(!isPerWorktree("refs/heads/main"));
}
