const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "brotli",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.addIncludePath(b.path("upstream/c"));
    lib.addIncludePath(b.path("upstream/c/include"));
    lib.addCSourceFiles(.{
        .root = b.path("upstream/c"),
        .files = sources,
        .flags = &.{},
    });
    lib.installHeadersDirectory(b.path("upstream/c/include/brotli"), "brotli", .{});

    switch (target.result.os.tag) {
        .linux => lib.root_module.addCMacro("OS_LINUX", "1"),
        .freebsd => lib.root_module.addCMacro("OS_FREEBSD", "1"),
        else => {},
    }

    b.installArtifact(lib);
}

const sources = &.{
    "common/constants.c",
    "common/context.c",
    "common/dictionary.c",
    "common/platform.c",
    "common/shared_dictionary.c",
    "common/transform.c",
    "dec/bit_reader.c",
    "dec/decode.c",
    "dec/huffman.c",
    "dec/state.c",
    "enc/backward_references.c",
    "enc/backward_references_hq.c",
    "enc/bit_cost.c",
    "enc/block_splitter.c",
    "enc/brotli_bit_stream.c",
    "enc/cluster.c",
    "enc/command.c",
    "enc/compound_dictionary.c",
    "enc/compress_fragment.c",
    "enc/compress_fragment_two_pass.c",
    "enc/dictionary_hash.c",
    "enc/encode.c",
    "enc/encoder_dict.c",
    "enc/entropy_encode.c",
    "enc/fast_log.c",
    "enc/histogram.c",
    "enc/literal_cost.c",
    "enc/memory.c",
    "enc/metablock.c",
    "enc/static_dict.c",
    "enc/utf8_util.c",
};
