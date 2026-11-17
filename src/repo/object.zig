//! Parsers for the payloads of tree, commit and tag objects.

const std = @import("std");
const Oid = @import("odb.zig").Oid;

pub const TreeItem = struct {
    mode: u32,
    name: []const u8,
    oid: Oid,
};

pub const TreeIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *TreeIterator) !?TreeItem {
        if (self.pos >= self.data.len) return null;
        const rest = self.data[self.pos..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.CorruptObject;
        const nul = std.mem.indexOfScalarPos(u8, rest, space + 1, 0) orelse return error.CorruptObject;
        if (rest.len - nul - 1 < 20) return error.CorruptObject;
        const mode = std.fmt.parseInt(u32, rest[0..space], 8) catch return error.CorruptObject;
        const item: TreeItem = .{
            .mode = mode,
            .name = rest[space + 1 .. nul],
            .oid = .{ .bytes = rest[nul + 1 ..][0..20].* },
        };
        self.pos += nul + 1 + 20;
        return item;
    }
};

pub const EntryKind = enum { file, executable, symlink, directory, submodule };

pub fn kindOfMode(mode: u32) EntryKind {
    return switch (mode & 0o170000) {
        0o040000 => .directory,
        0o160000 => .submodule,
        0o120000 => .symlink,
        else => if (mode & 0o111 != 0) .executable else .file,
    };
}

fn headerOid(data: []const u8, field: []const u8) !Oid {
    if (!std.mem.startsWith(u8, data, field)) return error.CorruptObject;
    const rest = data[field.len..];
    if (rest.len < Oid.hex_len or (rest.len > Oid.hex_len and rest[Oid.hex_len] != '\n')) return error.CorruptObject;
    return Oid.parseHex(rest[0..Oid.hex_len]) catch error.CorruptObject;
}

pub fn commitTree(data: []const u8) !Oid {
    return headerOid(data, "tree ");
}

pub fn tagTarget(data: []const u8) !Oid {
    return headerOid(data, "object ");
}

const testing = std.testing;

test "tree iteration and mode kinds" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const a: [20]u8 = @splat(0xaa);
    const b: [20]u8 = @splat(0xbb);
    try buf.appendSlice(testing.allocator, "40000 docs\x00");
    try buf.appendSlice(testing.allocator, &a);
    try buf.appendSlice(testing.allocator, "100755 run.sh\x00");
    try buf.appendSlice(testing.allocator, &b);

    var it: TreeIterator = .{ .data = buf.items };
    const first = (try it.next()).?;
    try testing.expectEqualStrings("docs", first.name);
    try testing.expectEqual(EntryKind.directory, kindOfMode(first.mode));
    try testing.expectEqual(a, first.oid.bytes);
    const second = (try it.next()).?;
    try testing.expectEqual(EntryKind.executable, kindOfMode(second.mode));
    try testing.expectEqual(@as(?TreeItem, null), try it.next());

    var bad: TreeIterator = .{ .data = "100644 x\x00short" };
    try testing.expectError(error.CorruptObject, bad.next());
}

test "commit and tag headers" {
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const oid = try Oid.parseHex(hex);
    try testing.expect((try commitTree("tree " ++ hex ++ "\nauthor x\n")).eql(oid));
    try testing.expect((try tagTarget("object " ++ hex ++ "\ntype commit\n")).eql(oid));
    try testing.expectError(error.CorruptObject, commitTree("parent " ++ hex ++ "\n"));
    try testing.expectError(error.CorruptObject, commitTree("tree " ++ hex ++ "x"));
}
