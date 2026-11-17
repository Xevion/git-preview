const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmark = buildCmarkGfm(b, target, optimize);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cmark", .module = cmark.module },
        },
    });
    exe_mod.linkLibrary(cmark.lib);
    addAssets(b, exe_mod);

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

const Cmark = struct {
    lib: *std.Build.Step.Compile,
    module: *std.Build.Module,
};

/// Compiles cmark-gfm and its GFM extensions from the upstream tarball, standing in for its CMake build.
fn buildCmarkGfm(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Cmark {
    const dep = b.dependency("cmark_gfm", .{});

    // Headers CMake would normally generate; static linking makes the export macros empty.
    const gen = b.addWriteFiles();
    _ = gen.add("cmark-gfm_export.h",
        \\#ifndef CMARK_GFM_EXPORT_H
        \\#define CMARK_GFM_EXPORT_H
        \\#define CMARK_GFM_EXPORT
        \\#define CMARK_GFM_NO_EXPORT
        \\#endif
        \\
    );
    _ = gen.add("cmark-gfm_version.h",
        \\#ifndef CMARK_GFM_VERSION_H
        \\#define CMARK_GFM_VERSION_H
        \\#define CMARK_GFM_VERSION ((0 << 24) | (29 << 16) | (0 << 8) | 13)
        \\#define CMARK_GFM_VERSION_STRING "0.29.0.gfm.13"
        \\#endif
        \\
    );
    _ = gen.add("config.h",
        \\#ifndef CMARK_CONFIG_H
        \\#define CMARK_CONFIG_H
        \\#include <stdbool.h>
        \\#define HAVE___BUILTIN_EXPECT
        \\#define HAVE___ATTRIBUTE__
        \\#define CMARK_ATTRIBUTE(list) __attribute__ (list)
        \\#define CMARK_INLINE inline
        \\#endif
        \\
    );
    const gen_dir = gen.getDirectory();

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_]std.Build.LazyPath{ gen_dir, dep.path("src"), dep.path("extensions") }) |inc| {
        lib_mod.addIncludePath(inc);
    }
    const flags: []const []const u8 = &.{ "-std=c99", "-DCMARK_GFM_STATIC_DEFINE", "-DCMARK_GFM_EXTENSIONS_STATIC_DEFINE" };
    lib_mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{
            "cmark.c",            "node.c",        "iterator.c",       "blocks.c",
            "inlines.c",          "scanners.c",    "utf8.c",           "buffer.c",
            "references.c",       "footnotes.c",   "map.c",            "render.c",
            "man.c",              "xml.c",         "html.c",           "commonmark.c",
            "plaintext.c",        "latex.c",       "houdini_href_e.c", "houdini_html_e.c",
            "houdini_html_u.c",   "cmark_ctype.c", "arena.c",          "linked_list.c",
            "syntax_extension.c", "registry.c",    "plugin.c",
        },
        .flags = flags,
    });
    lib_mod.addCSourceFiles(.{
        .root = dep.path("extensions"),
        .files = &.{
            "core-extensions.c", "table.c",        "strikethrough.c", "autolink.c",
            "tagfilter.c",       "ext_scanners.c", "tasklist.c",
        },
        .flags = flags,
    });

    const lib = b.addLibrary(.{
        .name = "cmark-gfm",
        .linkage = .static,
        .root_module = lib_mod,
    });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/cmark.h"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]std.Build.LazyPath{ gen_dir, dep.path("src"), dep.path("extensions") }) |inc| {
        translate.addIncludePath(inc);
    }

    return .{ .lib = lib, .module = translate.createModule() };
}
