const std = @import("std");
const markdown = @import("render/markdown.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    std.testing.refAllDecls(@This());
    _ = markdown;
}
