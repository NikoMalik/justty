const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("highway", .{});

    const lib = b.addStaticLibrary(.{
        .name = "highway",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibCpp();
    lib.addIncludePath(upstream.path(""));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",

        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
        "-D__TIME__=\"redacted\"",

        "-fmerge-all-constants",

        // Warnings
        "-Wall",
        "-Wextra",

        "-Wconversion",
        "-Wsign-conversion",
        "-Wvla",
        "-Wnon-virtual-dtor",

        "-Wfloat-overflow-conversion",
        "-Wfloat-zero-conversion",
        "-Wfor-loop-analysis",
        "-Wgnu-redeclared-enum",
        "-Winfinite-recursion",
        "-Wself-assign",
        "-Wstring-conversion",
        "-Wtautological-overlap-compare",
        "-Wthread-safety-analysis",
        "-Wundefined-func-template",

        "-fno-cxx-exceptions",
        "-fno-slp-vectorize",
        "-fno-vectorize",
    });

    lib.addCSourceFiles(.{ .flags = flags.items, .files = &.{"joke.cpp"} });
    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .flags = flags.items,
        .files = &.{
            "hwy/abort.cc",
            "hwy/aligned_allocator.cc",
            "hwy/nanobenchmark.cc",
            "hwy/per_target.cc",
            "hwy/print.cc",
            "hwy/targets.cc",
            "hwy/timer.cc",
        },
    });
    lib.installHeadersDirectory(
        upstream.path("hwy"),
        "hwy",
        .{ .include_extensions = &.{ ".h", "-inl.h" } }, // Fixed typo
    );

    b.installArtifact(lib);
}
