const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "harfbuzz",
        .target = target,
        .optimize = optimize,
    });
    lib.addCSourceFile(
        .{
            .flags = &.{
                "-O3",
                "-march=native",

                "-flto",
                "-ffunction-sections",
                "-fdata-sections",
            },
            .file = upstream.path("src/harfbuzz.cc"),
        },
    );
    lib.linkLibCpp();
    lib.installHeadersDirectory(upstream.path("src"), "harfbuzz", .{
        .exclude_extensions = &.{".cc"},
    });
    lib.root_module.addCMacro("HAVE_FREETYPE", "1");

    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        lib.linkLibrary(dep.artifact("freetype"));
    }
    b.installArtifact(lib);
}
