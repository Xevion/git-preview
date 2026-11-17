const std = @import("std");
const cmark = @import("build/cmark.zig");
const lexbor = @import("build/lexbor.zig");
const emoji = @import("build/emoji.zig");
const libgit2 = @import("build/libgit2.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cmark.build(b, target, optimize).addTo(exe_mod, "cmark");
    lexbor.build(b, target, optimize).addTo(exe_mod, "lexbor");
    libgit2.build(b, target, optimize).addTo(exe_mod, "git2");
    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("LetterCasing", zg.module("LetterCasing"));
    exe_mod.addImport("GeneralCategories", zg.module("GeneralCategories"));
    exe_mod.addImport("clap", b.dependency("clap", .{ .target = target, .optimize = optimize }).module("clap"));
    addAssets(b, exe_mod);
    emoji.addTo(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "git-preview",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run git-preview").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Type-checks without emitting a binary, for fast feedback.
    const check_exe = b.addExecutable(.{ .name = "git-preview", .root_module = exe_mod });
    b.step("check", "Type-check without installing").dependOn(&check_exe.step);
}

/// Octicons the renderer emits; each is reachable as `@embedFile("octicon/<name>")`.
const octicon_names = [_][]const u8{ "link", "info", "light-bulb", "report", "alert", "stop" };

/// Exposes pinned upstream assets to `@embedFile`, so updating one is a `zig fetch --save` of a newer tag.
fn addAssets(b: *std.Build, mod: *std.Build.Module) void {
    const octicons = b.dependency("octicons", .{});
    for (octicon_names) |name| {
        mod.addAnonymousImport(b.fmt("octicon/{s}", .{name}), .{
            .root_source_file = octicons.path(b.fmt("icons/{s}-16.svg", .{name})),
        });
    }
    mod.addAnonymousImport("octicons.LICENSE", .{ .root_source_file = octicons.path("LICENSE") });

    const css = b.dependency("github_markdown_css", .{});
    mod.addAnonymousImport("github-markdown.css", .{ .root_source_file = css.path("github-markdown.css") });
    mod.addAnonymousImport("github-markdown-css.LICENSE", .{ .root_source_file = css.path("license") });
}
