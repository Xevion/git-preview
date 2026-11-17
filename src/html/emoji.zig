const std = @import("std");
const table = @import("emoji_table");

pub const Emoji = union(enum) {
    unicode: []const u8,
    /// GitHub-only emoji served as images, like `:octocat:`.
    custom: []const u8,
};

pub fn lookup(name: []const u8) ?Emoji {
    const Ctx = struct {
        fn order(key: []const u8, e: table.Entry) std.math.Order {
            return std.mem.order(u8, key, e.name);
        }
    };
    const i = std.sort.binarySearch(table.Entry, &table.entries, name, Ctx.order) orelse return null;
    const e = table.entries[i];
    return if (e.value) |v| .{ .unicode = v } else .{ .custom = e.name };
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '+' or ch == '-';
}

pub const Match = struct { start: usize, end: usize, emoji: Emoji };

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Finds the next known `:name:` shortcode at or after `from`; like GitHub, it must not touch word characters.
pub fn next(text: []const u8, from: usize) ?Match {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, text, i, ':')) |open| {
        var j = open + 1;
        while (j < text.len and isNameChar(text[j])) j += 1;
        const bounded = (open == 0 or !isWordByte(text[open - 1])) and (j + 1 >= text.len or !isWordByte(text[j + 1]));
        if (j < text.len and text[j] == ':' and j > open + 1 and bounded) {
            if (lookup(text[open + 1 .. j])) |e| return .{ .start = open, .end = j + 1, .emoji = e };
            i = j;
        } else {
            i = open + 1;
        }
    }
    return null;
}

test "finds shortcodes the way GitHub's emoji filter does" {
    const text = "a:b:c :rocket::+1: :notanemoji: :octocat:";
    const rocket = next(text, 0).?;
    try std.testing.expectEqualStrings(":rocket:", text[rocket.start..rocket.end]);
    try std.testing.expectEqualStrings("\u{1f680}", rocket.emoji.unicode);
    const thumbs = next(text, rocket.end).?;
    try std.testing.expectEqualStrings(":+1:", text[thumbs.start..thumbs.end]);
    const octocat = next(text, thumbs.end).?;
    try std.testing.expectEqualStrings("octocat", octocat.emoji.custom);
    try std.testing.expect(next(text, octocat.end) == null);
}
