//! Parser for git's INI-like config format. `include` directives are not followed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// Lowercased.
    section: []const u8,
    /// Case-sensitive, except for the legacy `[section.sub]` form which git lowercases.
    subsection: ?[]const u8,
    /// Lowercased.
    key: []const u8,
    /// Null for a bare key, which git treats as boolean true.
    value: ?[]const u8,

    pub fn is(self: Entry, section: []const u8, key: []const u8) bool {
        return std.mem.eql(u8, self.section, section) and std.mem.eql(u8, self.key, key);
    }
};

/// Parses `text` into entries in file order. All memory comes from `arena`.
pub fn parse(arena: Allocator, text: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var section: ?[]const u8 = null;
    var subsection: ?[]const u8 = null;
    var i: usize = 0;

    while (i < text.len) {
        const c = text[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '#', ';' => i = skipLine(text, i),
            '[' => {
                i = try parseHeader(arena, text, i + 1, &section, &subsection);
            },
            else => {
                const sec = section orelse return error.InvalidConfig;
                const start = i;
                while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) i += 1;
                if (i == start) return error.InvalidConfig;
                const key = try std.ascii.allocLowerString(arena, text[start..i]);
                while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
                var value: ?[]const u8 = null;
                if (i < text.len and text[i] == '=') {
                    value, i = try parseValue(arena, text, i + 1);
                }
                try entries.append(arena, .{ .section = sec, .subsection = subsection, .key = key, .value = value });
            },
        }
    }
    return entries.items;
}

fn skipLine(text: []const u8, from: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, from, '\n')) |nl| nl + 1 else text.len;
}

fn parseHeader(
    arena: Allocator,
    text: []const u8,
    from: usize,
    section: *?[]const u8,
    subsection: *?[]const u8,
) !usize {
    var i = from;
    const start = i;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == '.')) i += 1;
    const name = text[start..i];
    if (name.len == 0) return error.InvalidConfig;

    var sub: ?[]const u8 = null;
    var sec_name = name;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i < text.len and text[i] == '"') {
        i += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (i >= text.len or text[i] == '\n') return error.InvalidConfig;
            const ch = text[i];
            i += 1;
            if (ch == '"') break;
            if (ch == '\\') {
                if (i >= text.len or text[i] == '\n') return error.InvalidConfig;
                try buf.append(arena, text[i]);
                i += 1;
            } else try buf.append(arena, ch);
        }
        sub = buf.items;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    } else if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        sec_name = name[0..dot];
        sub = try std.ascii.allocLowerString(arena, name[dot + 1 ..]);
    }
    if (i >= text.len or text[i] != ']') return error.InvalidConfig;

    section.* = try std.ascii.allocLowerString(arena, sec_name);
    subsection.* = sub;
    return i + 1;
}

fn parseValue(arena: Allocator, text: []const u8, from: usize) !struct { []const u8, usize } {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    var buf: std.ArrayList(u8) = .empty;
    var keep: usize = 0;
    var quoted = false;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        switch (c) {
            '\n' => break,
            '\r' => if (quoted) {
                try buf.append(arena, c);
                keep = buf.items.len;
            },
            '"' => {
                quoted = !quoted;
                keep = buf.items.len;
            },
            '#', ';' => if (quoted) {
                try buf.append(arena, c);
                keep = buf.items.len;
            } else {
                i = skipLine(text, i);
                break;
            },
            '\\' => {
                if (i >= text.len) return error.InvalidConfig;
                const e = text[i];
                i += 1;
                switch (e) {
                    '\n' => continue,
                    '\r' => {
                        if (i < text.len and text[i] == '\n') i += 1;
                        continue;
                    },
                    'n' => try buf.append(arena, '\n'),
                    't' => try buf.append(arena, '\t'),
                    'b' => try buf.append(arena, 8),
                    else => try buf.append(arena, e),
                }
                keep = buf.items.len;
            },
            else => {
                try buf.append(arena, c);
                if (quoted or (c != ' ' and c != '\t')) keep = buf.items.len;
            },
        }
    }
    return .{ buf.items[0..keep], i };
}

const testing = std.testing;

fn parseTest(arena: *std.heap.ArenaAllocator, text: []const u8) ![]Entry {
    return parse(arena.allocator(), text);
}

test "sections, subsections and case folding" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = try parseTest(&arena,
        \\[Core]
        \\  RepositoryFormatVersion = 0
        \\[remote "Origin"]
        \\  URL = https://example.com/a.git
        \\  fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch.Legacy]
        \\  merge
    );
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expect(entries[0].is("core", "repositoryformatversion"));
    try testing.expectEqualStrings("0", entries[0].value.?);
    try testing.expect(entries[1].is("remote", "url"));
    try testing.expectEqualStrings("Origin", entries[1].subsection.?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", entries[2].value.?);
    try testing.expectEqualStrings("legacy", entries[3].subsection.?);
    try testing.expectEqual(@as(?[]const u8, null), entries[3].value);
}

test "values: quotes, comments, escapes, continuation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const entries = try parseTest(
        &arena,
        "# leading comment\n" ++
            "; another\n" ++
            "[s]\r\n" ++
            "a = plain value   # trailing\r\n" ++
            "b = \"  quoted ; not a comment  \"  ; real comment\n" ++
            "c = tab\\there\\\\ \\\"q\\\"\n" ++
            "d = one \\\n" ++
            "two\n" ++
            "e =\n" ++
            "f = a\"b  c\"d\n" ++
            "[x \"sub \\\"quoted\\\" \\\\\"] k = v\n",
    );
    try testing.expectEqualStrings("plain value", entries[0].value.?);
    try testing.expectEqualStrings("  quoted ; not a comment  ", entries[1].value.?);
    try testing.expectEqualStrings("tab\there\\ \"q\"", entries[2].value.?);
    try testing.expectEqualStrings("one two", entries[3].value.?);
    try testing.expectEqualStrings("", entries[4].value.?);
    try testing.expectEqualStrings("ab  cd", entries[5].value.?);
    try testing.expectEqualStrings("sub \"quoted\" \\", entries[6].subsection.?);
    try testing.expectEqualStrings("v", entries[6].value.?);
}

test "malformed input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidConfig, parseTest(&arena, "k = v\n"));
    try testing.expectError(error.InvalidConfig, parseTest(&arena, "[s\nk = v\n"));
    try testing.expectError(error.InvalidConfig, parseTest(&arena, "[s \"x\n]\n"));
}
