const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary(.{
        .name = "simdutf",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibCpp();
    lib.addIncludePath(b.path("vendor"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",
        "-flto",
        "-fno-exceptions",
        "-DNDEBUG",
        "-std=c++17",
        "-ffunction-sections",
        "-fdata-sections",
    });
    defer flags.deinit();

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{
            "vendor/simdutf.cpp",
        },
    });
    lib.installHeadersDirectory(
        b.path("vendor"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);
}
