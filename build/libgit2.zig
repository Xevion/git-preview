const std = @import("std");
const CLib = @import("CLib.zig");
const sources = @import("libgit2_sources.zig");

/// Compiles libgit2 for reading local repositories (no TLS, SSH or NTLM), standing in for its CMake build.
/// Tested on Linux (glibc and musl). macOS cross-compiles and links but has never been run; Windows is unsupported.
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) CLib {
    const sha256 = b.option(bool, "sha256", "Open SHA-256 repositories (libgit2 marks this experimental)") orelse true;
    const os = target.result.os.tag;
    if (os == .windows) std.debug.panic("libgit2: Windows targets are not supported by this build", .{});

    const src = b.dependency("libgit2", .{});
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });

    const features = b.addConfigHeader(
        .{ .style = .{ .cmake = src.path("src/util/git2_features.h.in") } },
        .{
            .GIT_THREADS = 1,
            .GIT_USE_NSEC = 1,
            .GIT_USE_FUTIMENS = 1,
            .GIT_IO_POLL = 1,
            .GIT_IO_SELECT = 1,
            .GIT_SHA1_COLLISIONDETECT = 1,
            .GIT_SHA256_BUILTIN = 1,
            .GIT_COMPRESSION_BUILTIN = 1,
            .GIT_HTTPPARSER_BUILTIN = 1,
            .GIT_ARCH_64 = @as(?u1, if (target.result.ptrBitWidth() == 64) 1 else null),
            .GIT_ARCH_32 = @as(?u1, if (target.result.ptrBitWidth() == 32) 1 else null),
        },
    );
    if (os == .macos) {
        features.addValues(.{
            .GIT_USE_STAT_MTIMESPEC = 1,
            .GIT_REGEX_REGCOMP_L = 1,
            .GIT_QSORT_BSD = 1,
        });
    } else {
        features.addValues(.{
            .GIT_USE_STAT_MTIM = 1,
            .GIT_RAND_GETENTROPY = 1,
            .GIT_REGEX_REGCOMP = 1,
        });
    }
    mod.addConfigHeader(features);

    const base_flags: []const []const u8 = &.{ "-DHAVE_CONFIG_H", "-fno-sanitize=undefined" };
    const flags = if (sha256)
        std.mem.concat(b.allocator, []const u8, &.{ base_flags, &.{"-DGIT_EXPERIMENTAL_SHA256=1"} }) catch @panic("OOM")
    else
        base_flags;
    const sha1dc_flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{
        "-DSHA1DC_NO_STANDARD_INCLUDES",
        "-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\"",
        "-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\"",
    } }) catch @panic("OOM");

    for ([_][]const u8{ "src/libgit2", "src/util", "include", "deps/zlib", "deps/xdiff", "deps/llhttp" }) |dir| {
        mod.addIncludePath(src.path(dir));
    }
    mod.addCSourceFiles(.{ .root = src.path("src/libgit2"), .files = sources.libgit2, .flags = flags });
    mod.addCSourceFiles(.{ .root = src.path("src/util"), .files = sources.util, .flags = flags });
    mod.addCSourceFiles(.{ .root = src.path("src/util"), .files = sources.util_unix, .flags = flags });
    mod.addCSourceFiles(.{ .root = src.path("src/util"), .files = sources.util_sha256_builtin, .flags = flags });
    mod.addCSourceFiles(.{ .root = src.path("src/util"), .files = sources.util_sha1dc, .flags = sha1dc_flags });
    mod.addCSourceFiles(.{ .root = src.path("deps/xdiff"), .files = sources.xdiff, .flags = &.{ "-DHAVE_CONFIG_H", "-Wno-sign-compare" } });
    mod.addCSourceFiles(.{ .root = src.path("deps/llhttp"), .files = sources.llhttp, .flags = &.{"-Wno-unused-parameter"} });
    mod.addCSourceFiles(.{
        .root = src.path("deps/zlib"),
        .files = sources.zlib,
        .flags = &.{ "-DNO_VIZ", "-DSTDC", "-DNO_GZIP", "-DHAVE_SYS_TYPES_H", "-DHAVE_STDINT_H", "-DHAVE_STDDEF_H", "-DZ_HAVE_UNISTD_H" },
    });

    const lib = b.addLibrary(.{ .name = "git2", .linkage = .static, .root_module = mod });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/repo/libgit2.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(src.path("include"));
    if (sha256) translate.defineCMacro("GIT_EXPERIMENTAL_SHA256", "1");
    return .{ .lib = lib, .module = translate.createModule() };
}
