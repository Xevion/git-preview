//! Resolves GitHub's hashed class names (`prc-Link-Link-9ZwDx`, `LinkTitle__mIk9z9`) from their
//! stable stems, by indexing the class selectors of the template's own stylesheets.

const Classes = @This();

const std = @import("std");

/// Every class selector seen, deduplicated; slices point into the indexed CSS.
names: std.StringHashMapUnmanaged(void) = .empty,

pub fn deinit(self: *Classes, gpa: std.mem.Allocator) void {
    self.names.deinit(gpa);
}

pub fn index(self: *Classes, gpa: std.mem.Allocator, css: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, css, i, '.')) |dot| {
        var j = dot + 1;
        while (j < css.len and (std.ascii.isAlphanumeric(css[j]) or css[j] == '-' or css[j] == '_')) j += 1;
        if (j > dot + 1 and std.ascii.isAlphabetic(css[dot + 1])) try self.names.put(gpa, css[dot + 1 .. j], {});
        i = j;
    }
}

/// The hashed class for `stem` (`prc-Link-Link` or `LinkTitle`), or null when absent or ambiguous.
pub fn resolve(self: *const Classes, stem: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = self.names.keyIterator();
    while (it.next()) |k| {
        const name = k.*;
        if (name.len <= stem.len or !std.mem.startsWith(u8, name, stem)) continue;
        const rest = name[stem.len..];
        const hashed = (std.mem.startsWith(u8, rest, "__") and rest.len == 8) or
            (std.mem.startsWith(u8, stem, "prc-") and rest[0] == '-' and rest.len == 6);
        if (!hashed) continue;
        if (found) |f| if (!std.mem.eql(u8, f, name)) return null;
        found = name;
    }
    return found;
}

test "resolves unique stems and refuses ambiguous ones" {
    const gpa = std.testing.allocator;
    var cls: Classes = .{};
    defer cls.deinit(gpa);
    try cls.index(gpa, ".prc-Link-Link-9ZwDx{color:red}.prc-Button-ButtonBase-9n-Xk:hover{}" ++
        ".LinkTitle__mIk9z9 .Box_1__uz309Z,.Box_1__aaaaaa{} .prc-Link-LinkExtra-zzzzz{}");
    try std.testing.expectEqualStrings("prc-Link-Link-9ZwDx", cls.resolve("prc-Link-Link").?);
    try std.testing.expectEqualStrings("prc-Button-ButtonBase-9n-Xk", cls.resolve("prc-Button-ButtonBase").?);
    try std.testing.expectEqualStrings("LinkTitle__mIk9z9", cls.resolve("LinkTitle").?);
    try std.testing.expect(cls.resolve("Box_1") == null);
    try std.testing.expect(cls.resolve("Missing") == null);
}
