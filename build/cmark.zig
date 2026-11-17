const std = @import("std");
const CLib = @import("CLib.zig");

/// Compiles cmark-gfm and its GFM extensions from the upstream tarball, standing in for its CMake build.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) CLib {
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
