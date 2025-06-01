const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("fcft", .{});

    const utf8proc_dep = b.lazyDependency("utf8proc", .{});

    const generate_emoji = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("generate-emoji-data.py"),
        b.pathFromRoot("emoji-data.txt"),
    });

    const generate_unicode = b.addSystemCommand(&.{
        "env",
        "LC_ALL=C",
        upstream.path("generate-unicode-precompose.sh").getPath(b),
        upstream.path("UnicodeData.txt").getPath(b),
    });

    const generate_version = b.addSystemCommand(&.{
        "env",
        "LC_ALL=C",
        upstream.path("generate-version.sh").getPath(b),
        "3.3.1",
        upstream.path("").getPath(b),
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

    lib.linkSystemLibrary("pixman-1");
    lib.linkSystemLibrary("freetype2");
    lib.linkSystemLibrary("harfbuzz");
    lib.linkSystemLibrary("fontconfig");
    lib.linkLibrary(utf8proc_dep.?.artifact("utf8proc"));
    // if (utf8proc_dep.found()) lib.linkLibrary(utf8proc_dep.artifact("libutf8proc"));
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",
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
