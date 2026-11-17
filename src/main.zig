const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = @import("render/markdown.zig");
    _ = @import("render/slug.zig");
    _ = @import("render/sanitize.zig");
    _ = @import("repo/Repo.zig");
}
