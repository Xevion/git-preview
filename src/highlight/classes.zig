//! Maps tree-sitter capture names onto GitHub's `pl-*` token classes.

const std = @import("std");

pub const Class = enum {
    none,
    comment,
    constant,
    entity,
    entity_tag,
    entity_attr,
    keyword,
    string,
    regexp,
    variable,
    escape,
    heading,
    uri,
    inserted,
    deleted,
    changed,

    pub fn css(self: Class) []const u8 {
        return switch (self) {
            .none => "",
            .comment => "pl-c",
            .constant => "pl-c1",
            .entity => "pl-en",
            .entity_tag => "pl-ent",
            .entity_attr => "pl-e",
            .keyword => "pl-k",
            .string => "pl-s",
            .regexp => "pl-sr",
            .variable => "pl-v",
            .escape => "pl-cce",
            .heading => "pl-mh",
            .uri => "pl-corl",
            .inserted => "pl-mi1",
            .deleted => "pl-md",
            .changed => "pl-mc",
        };
    }
};

const Entry = struct { name: []const u8, class: Class };

/// Longest dotted prefix wins, so an entry only needs to exist where it differs from its parent.
const table = [_]Entry{
    .{ .name = "comment", .class = .comment },
    .{ .name = "string", .class = .string },
    .{ .name = "string.regexp", .class = .regexp },
    .{ .name = "string.escape", .class = .escape },
    .{ .name = "escape", .class = .escape },
    .{ .name = "character", .class = .string },
    .{ .name = "character.special", .class = .escape },
    .{ .name = "keyword", .class = .keyword },
    .{ .name = "operator", .class = .keyword },
    .{ .name = "constant", .class = .constant },
    .{ .name = "number", .class = .constant },
    .{ .name = "boolean", .class = .constant },
    .{ .name = "function", .class = .entity },
    .{ .name = "function.call", .class = .none },
    .{ .name = "function.method.call", .class = .none },
    .{ .name = "function.builtin", .class = .constant },
    .{ .name = "type.builtin", .class = .none },
    .{ .name = "variable.builtin", .class = .constant },
    .{ .name = "variable.parameter", .class = .variable },
    .{ .name = "attribute", .class = .entity },
    .{ .name = "diff.plus", .class = .inserted },
    .{ .name = "diff.minus", .class = .deleted },
    .{ .name = "diff.delta", .class = .changed },
    .{ .name = "text.title", .class = .heading },
    .{ .name = "text.literal", .class = .constant },
    .{ .name = "text.uri", .class = .uri },
    .{ .name = "string.special.key", .class = .entity_tag },
    .{ .name = "tag", .class = .entity_tag },
    .{ .name = "tag.attribute", .class = .entity_attr },
};

pub fn classify(capture: []const u8) Class {
    var name = capture;
    while (true) {
        for (table) |e| if (std.mem.eql(u8, e.name, name)) return e.class;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .none;
        name = name[0..dot];
    }
}

test "longest dotted prefix wins" {
    try std.testing.expectEqual(Class.keyword, classify("keyword.control.return"));
    try std.testing.expectEqual(Class.regexp, classify("string.regexp"));
    try std.testing.expectEqual(Class.string, classify("string.special.url"));
    try std.testing.expectEqual(Class.constant, classify("function.builtin"));
    try std.testing.expectEqual(Class.none, classify("function.call"));
    try std.testing.expectEqual(Class.none, classify("punctuation.bracket"));
    try std.testing.expectEqual(Class.none, classify("spell"));
}
