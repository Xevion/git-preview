//! A C library compiled from a dependency tarball, plus its translated headers as a Zig module.

const std = @import("std");

lib: *std.Build.Step.Compile,
module: *std.Build.Module,

/// Links the library and exposes its headers to `mod` as `@import(name)`.
pub fn addTo(self: @This(), mod: *std.Build.Module, name: []const u8) void {
    mod.addImport(name, self.module);
    mod.linkLibrary(self.lib);
}
