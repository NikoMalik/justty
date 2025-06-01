const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("fcft", .{});

    const utf8proc_dep = b.lazyDependency("utf8proc", .{
        .target = target,
        .optimize = optimize,
    });
    const pixman_dep = b.lazyDependency("pixman", .{
        .target = target,
        .optimize = optimize,
    });
    const fontconfig_dep = b.lazyDependency("fontconfig", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_dep = b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const harfbuzz_dep = b.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });

    const generate_emoji = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("generate-emoji-data.py"),
        b.pathFromRoot("emoji-data.txt"),
    });

    const generate_unicode = b.addSystemCommand(&.{
        "env",
        "LC_ALL=C",
        b.pathFromRoot("generate-unicode-precompose.sh"),
        b.pathFromRoot("UnicodeData.txt"),
    });
    const generate_version = b.addSystemCommand(&.{
        "env",
        "LC_ALL=C",
        b.pathFromRoot("generate-version.sh"),
        "3.3.1",
        b.pathFromRoot(""),
    });
    const version_h = generate_version.addOutputFileArg("version.h");

    const emoji_data_h = generate_emoji.addOutputFileArg("emoji-data.h");

    const lib = b.addStaticLibrary(.{
        .name = "fcft",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    lib.addIncludePath(emoji_data_h.dirname());
    lib.addIncludePath(version_h.dirname());
    lib.step.dependOn(&generate_version.step);

    lib.addIncludePath(b.path(""));
    lib.addIncludePath(upstream.path(""));
    const unicode_data_h = generate_unicode.addOutputFileArg("unicode-compose-table.h");
    lib.addIncludePath(unicode_data_h.dirname());
    lib.step.dependOn(&generate_unicode.step);

    // pixman

    // lib.linkSystemLibrary("pixman-1"); // done static
    // lib.linkSystemLibrary("freetype2"); //done static
    // lib.linkSystemLibrary("harfbuzz"); //done static
    // lib.linkSystemLibrary("fontconfig"); // done static
    lib.linkLibrary(pixman_dep.?.artifact("pixman"));
    lib.addIncludePath(pixman_dep.?.path("upstream"));
    lib.addIncludePath(pixman_dep.?.path("upstream/pixman"));
    lib.addIncludePath(pixman_dep.?.path("include"));

    lib.linkLibrary(freetype_dep.?.artifact("freetype"));
    lib.addIncludePath(freetype_dep.?.path("upstream"));
    lib.addIncludePath(freetype_dep.?.path("upstream/include"));

    lib.linkLibrary(harfbuzz_dep.?.artifact("harfbuzz"));

    lib.linkLibrary(fontconfig_dep.?.artifact("fontconfig"));
    lib.addIncludePath(fontconfig_dep.?.path("override/include"));
    lib.addIncludePath(fontconfig_dep.?.path("upstream/"));

    lib.linkLibrary(utf8proc_dep.?.artifact("utf8proc"));
    lib.addIncludePath(utf8proc_dep.?.path("upstream"));
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",

        "-flto",
        "-ffunction-sections",
        "-fdata-sections",

        "-D_GNU_SOURCE=200809L",
        "-DFCFT_HAVE_HARFBUZZ",
        "-DFCFT_HAVE_UTF8PROC",
        "-fvisibility=default",
        "-D_XOPEN_SOURCE=700",

        "-DFCFT_EXPORT=__attribute__((visibility(\"default\")))",
    });
    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .flags = flags.items,
        .files = &.{
            "fcft.c",
            "log.c",
        },
    });

    lib.step.dependOn(&generate_emoji.step);

    lib.installHeadersDirectory(
        upstream.path("fcft"),
        "fcft",
        .{ .include_extensions = &.{ ".h", "-inl.h" } }, // Fixed typo
    );
    b.installArtifact(lib);
}
