//! Octicon markup (MIT, primer/octicons), embedded from the pinned upstream SVG files.

const std = @import("std");

pub const link = body("link");
pub const info = body("info");
pub const light_bulb = body("light-bulb");
pub const report = body("report");
pub const alert = body("alert");
pub const stop = body("stop");

/// The SVG's inner markup, with self-closing elements expanded the way GitHub serializes them.
fn body(comptime name: []const u8) []const u8 {
    const svg = @embedFile("octicon/" ++ name);
    comptime {
        @setEvalBranchQuota(100_000);
        const open_end = std.mem.indexOfScalar(u8, svg, '>').? + 1;
        const close = std.mem.lastIndexOf(u8, svg, "</svg>").?;
        const inner = svg[open_end..close];
        var out: []const u8 = "";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, inner, i, "/>")) |end| {
            const tag_start = std.mem.lastIndexOfScalar(u8, inner[0..end], '<').?;
            const name_end = std.mem.indexOfAnyPos(u8, inner, tag_start, " \t\n/").?;
            out = out ++ inner[i..end] ++ "></" ++ inner[tag_start + 1 .. name_end] ++ ">";
            i = end + 2;
        }
        const result = out ++ inner[i..];
        return result;
    }
}

test "expands self-closing paths to match GitHub's markup" {
    try std.testing.expect(std.mem.startsWith(u8, info, "<path d=\"M0 8a8"));
    try std.testing.expect(std.mem.endsWith(u8, info, "></path>"));
}
