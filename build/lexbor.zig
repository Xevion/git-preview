const std = @import("std");
const CLib = @import("CLib.zig");

/// Compiles lexbor's HTML parser and its dependencies; the list comes from `just lexbor-sources`.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) CLib {
    const dep = b.dependency("lexbor", .{});
    const flags: []const []const u8 = &.{ "-std=c99", "-DLEXBOR_STATIC", "-D_POSIX_C_SOURCE=199309L" };
    const lib_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    lib_mod.addIncludePath(dep.path("source"));
    lib_mod.addCSourceFiles(.{
        .root = dep.path("source/lexbor"),
        .files = @import("lexbor_sources.zig").modules,
        .flags = flags,
    });
    const port = if (target.result.os.tag == .windows) "windows_nt" else "posix";
    lib_mod.addCSourceFiles(.{
        .root = dep.path(b.fmt("source/lexbor/ports/{s}/lexbor/core", .{port})),
        .files = &.{ "perf.c", "memory.c", "fs.c" },
        .flags = flags,
    });
    const lib = b.addLibrary(.{ .name = "lexbor", .linkage = .static, .root_module = lib_mod });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/html/lexbor.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(dep.path("source"));
    translate.defineCMacro("LEXBOR_STATIC", null);
    return .{ .lib = lib, .module = translate.createModule() };
}
