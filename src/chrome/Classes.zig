//! Resolves GitHub's hashed class names (`prc-Link-Link-9ZwDx`, `LinkTitle__mIk9z9`) from their
//! stable stems, by indexing the class selectors of the template's own stylesheets.

const Classes = @This();

const std = @import("std");

/// Every class selector seen, with its first position across all indexed CSS; keys point into that CSS.
names: std.StringHashMapUnmanaged(usize) = .empty,
/// Bytes indexed so far, so positions in later sheets follow earlier ones.
indexed: usize = 0,

pub fn deinit(self: *Classes, gpa: std.mem.Allocator) void {
    self.names.deinit(gpa);
}

pub fn index(self: *Classes, gpa: std.mem.Allocator, css: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, css, i, '.')) |dot| {
        var j = dot + 1;
        while (j < css.len and (std.ascii.isAlphanumeric(css[j]) or css[j] == '-' or css[j] == '_')) j += 1;
        if (j > dot + 1 and std.ascii.isAlphabetic(css[dot + 1])) {
            const gop = try self.names.getOrPut(gpa, css[dot + 1 .. j]);
            if (!gop.found_existing) gop.value_ptr.* = self.indexed + dot;
        }
        i = j;
    }
    self.indexed += css.len;
}

fn isHashed(stem: []const u8, name: []const u8) bool {
    if (name.len <= stem.len or !std.mem.startsWith(u8, name, stem)) return false;
    const rest = name[stem.len..];
    return (std.mem.startsWith(u8, rest, "__") and rest.len == 8) or
        (std.mem.startsWith(u8, stem, "prc-") and rest[0] == '-' and rest.len == 6);
}

/// The hashed class for `stem` (`prc-Link-Link` or `LinkTitle`), or null when absent or ambiguous.
pub fn resolve(self: *const Classes, stem: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = self.names.keyIterator();
    while (it.next()) |k| {
        if (!isHashed(stem, k.*)) continue;
        if (found) |f| if (!std.mem.eql(u8, f, k.*)) return null;
        found = k.*;
    }
    return found;
}

/// Like `resolve`, but several components reuse a stem (`emptyState`, `nameLink`); a CSS module's
/// rules are emitted together, so the candidate nearest to a sibling class of the same module wins.
pub fn resolveNear(self: *const Classes, stem: []const u8, sibling: []const u8) ?[]const u8 {
    const anchor = self.names.get(sibling) orelse return self.resolve(stem);
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    var it = self.names.iterator();
    while (it.next()) |e| {
        if (!isHashed(stem, e.key_ptr.*)) continue;
        const pos = e.value_ptr.*;
        const dist = if (pos > anchor) pos - anchor else anchor - pos;
        if (dist < best_dist) {
            best = e.key_ptr.*;
            best_dist = dist;
        }
    }
    return best;
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

test "breaks stem collisions by the module a sibling class belongs to" {
    const gpa = std.testing.allocator;
    var cls: Classes = .{};
    defer cls.deinit(gpa);
    try cls.index(gpa, ".avatarGrid___nXATx{}.emptyState__4RNm3Z{}");
    const padding: [200]u8 = @splat(' ');
    try cls.index(gpa, &padding ++ ".tagsLink__a4dr3v{}.emptyState__8cgPdc{}");
    try std.testing.expect(cls.resolve("emptyState") == null);
    try std.testing.expectEqualStrings("emptyState__4RNm3Z", cls.resolveNear("emptyState", "avatarGrid___nXATx").?);
    try std.testing.expectEqualStrings("emptyState__8cgPdc", cls.resolveNear("emptyState", "tagsLink__a4dr3v").?);
}
