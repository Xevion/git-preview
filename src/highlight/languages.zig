//! Fence-info resolution and the GitHub block class, over the languages selected at build time.

const std = @import("std");
const config = @import("highlight_config");

pub const Row = struct {
    name: []const u8,
    scope: []const u8,
    aliases: []const []const u8,
    query_parts: usize,
    inline_lang: []const u8,
    operators_constant: bool,
};

/// Decodes the build's one-line-per-language table: name;scope;aliases;query count;inline language;operators constant.
fn parseRows(comptime text: []const u8) []const Row {
    @setEvalBranchQuota(100_000);
    comptime {
        var out: []const Row = &.{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, ';');
            const name = f.next().?;
            const scope = f.next().?;
            const alias_field = f.next().?;
            const parts = f.next().?;
            const inline_lang = f.next().?;
            const operators_constant = f.next().?;
            var aliases: []const []const u8 = &.{};
            if (alias_field.len > 0) {
                var it = std.mem.splitScalar(u8, alias_field, ',');
                while (it.next()) |alias| aliases = aliases ++ [_][]const u8{alias};
            }
            out = out ++ [_]Row{.{
                .name = name,
                .scope = scope,
                .aliases = aliases,
                .query_parts = std.fmt.parseInt(usize, parts, 10) catch unreachable,
                .inline_lang = inline_lang,
                .operators_constant = std.mem.eql(u8, operators_constant, "1"),
            }};
        }
        return out;
    }
}

pub const rows = parseRows(config.languages);

/// Index into `rows` for a fence language token, matching names and aliases case-insensitively.
pub fn resolve(info: []const u8) ?usize {
    return resolveIn(rows, info);
}

pub fn resolveIn(table: anytype, info: []const u8) ?usize {
    var buf: [32]u8 = undefined;
    if (info.len == 0 or info.len > buf.len) return null;
    const key = std.ascii.lowerString(&buf, info);
    for (table, 0..) |row, i| {
        if (row.scope.len == 0) continue;
        if (std.mem.eql(u8, row.name, key)) return i;
        for (row.aliases) |alias| if (std.mem.eql(u8, alias, key)) return i;
    }
    return null;
}

const test_rows = [_]struct {
    name: []const u8,
    scope: []const u8,
    aliases: []const []const u8,
}{
    .{ .name = "javascript", .scope = "source.js", .aliases = &.{ "js", "jsx" } },
    .{ .name = "cpp", .scope = "source.c++", .aliases = &.{ "c++", "cxx" } },
    .{ .name = "markdown_inline", .scope = "", .aliases = &.{} },
};

test "names and aliases resolve case-insensitively" {
    try std.testing.expectEqual(@as(?usize, 0), resolveIn(test_rows, "js"));
    try std.testing.expectEqual(@as(?usize, 0), resolveIn(test_rows, "JavaScript"));
    try std.testing.expectEqual(@as(?usize, 1), resolveIn(test_rows, "C++"));
    try std.testing.expectEqual(@as(?usize, 1), resolveIn(test_rows, "cxx"));
}

test "unknown, empty and internal languages do not resolve" {
    try std.testing.expectEqual(@as(?usize, null), resolveIn(test_rows, "brainfuck"));
    try std.testing.expectEqual(@as(?usize, null), resolveIn(test_rows, ""));
    try std.testing.expectEqual(@as(?usize, null), resolveIn(test_rows, "markdown_inline"));
    try std.testing.expectEqual(@as(?usize, null), resolveIn(test_rows, &@as([40]u8, @splat('x'))));
}

test "every selected language has a unique name and unambiguous aliases" {
    for (rows, 0..) |row, i| {
        if (row.scope.len == 0) continue;
        try std.testing.expectEqual(@as(?usize, i), resolve(row.name));
        for (row.aliases) |alias| try std.testing.expectEqual(@as(?usize, i), resolve(alias));
    }
}
