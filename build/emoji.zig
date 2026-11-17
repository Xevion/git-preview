const std = @import("std");

/// Generates the emoji table from the pinned gemoji release and exposes it as `@import("emoji_table")`.
pub fn addTo(b: *std.Build, mod: *std.Build.Module) void {
    const gen = b.addExecutable(.{
        .name = "emoji_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/emoji_gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(gen);
    run.addFileArg(b.dependency("gemoji", .{}).path("db/emoji.json"));
    run.addFileArg(b.path("data/custom-emoji.txt"));
    const table = run.addOutputFileArg("emoji_table.zig");
    mod.addAnonymousImport("emoji_table", .{ .root_source_file = table });
}
