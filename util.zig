const std = @import("std");
const builtin = @import("builtin");

pub fn maxLen(input: []const u8) usize {
    return simd_base64_max_length(input.ptr, input.len);
}

pub fn decode_base64(input: []const u8, output: []u8) ![]const u8 {
    const res = simd_base64_decode(input.ptr, input.len, output.ptr);
    if (res < 0) return error.Base64Invalid;
    return output[0..@intCast(res)];
}

// pub fn (input: []const u8, output: []u32) ![]const u32 {
//     const res = simd_convert_utf8_to_utf32(input.ptr, input.len, output.ptr);
//     if (res == 0) return error.Utf8DecodeFailed;
//     return output[0..res];
// }

pub fn decode_utf8_to_utf32(input: []const u8, output: []u32) ![]const u32 {
    const res = simd_convert_utf8_to_utf32(input.ptr, input.len, output.ptr);
    if (res == 0) return error.Utf8DecodeFailed;
    return output[0..res];
}

pub fn detectEncodings(input: []const u8) u32 {
    return @bitCast(simd_detect_encodings(input.ptr, input.len));
}

test "detectEncodings" {
    const testing = std.testing;
    const utf8 = "Hello 😊";
    const utf16le = "\x48\x00\x65\x00\x6C\x00\x6C\x00\x6F\x00"; // "Hello" in UTF-16LE
    try testing.expect(detectEncodings(utf8) & 0x1 != 0); // UTF-8 flag
    try testing.expect(detectEncodings(utf16le) & 0x2 != 0); // UTF-16LE flag
}

pub fn utf32_len_from_utf8(input: []const u8) usize {
    return simd_utf32_len_from_utf8(input.ptr, input.len);
}

pub fn countUtf8CodePoints(input: []const u8) usize {
    return simd_count_utf8(input.ptr, input.len);
}

test "countUtf8CodePoints" {
    const testing = std.testing;
    try testing.expectEqual(6, countUtf8CodePoints("Привет")); // 6 characters
    try testing.expectEqual(1, countUtf8CodePoints("😊")); // 1 emoji
}

pub fn indexOf_char(input: []const u8, needle: u8) ?usize {
    const result = simd_index_of_char(input.ptr, input.len, needle);
    return if (result == input.len) null else result;
}

pub fn indexOfAny(slice: []const u8, comptime str: []const u8) ?usize {
    return switch (comptime str.len) {
        0 => @compileError("str cannot be empty"),
        1 => return indexOf_char(slice, str[0]),
        else => if (indexOf_any_char(slice, str)) |i|
            @intCast(i)
        else
            null,
    };
}

pub fn indexOf_any_char(haystack: []const u8, chars: []const u8) ?usize {
    if (haystack.len == 0 or chars.len == 0) {
        return null;
    }

    const result = simd_index_of_any_char(haystack.ptr, haystack.len, chars.ptr, chars.len);

    if (comptime isDebug) {
        const haystack_char = haystack[result];
        var found = false;
        for (chars) |c| {
            if (c == haystack_char) {
                found = true;
                break;
            }
        }
        if (!found) {
            @panic("Invalid character found in indexOfAnyChar");
        }
    }

    return if (result == haystack.len) null else result;
}

test "indexOfChar" {
    const testing = std.testing;
    const haystack = "hello world";
    try testing.expectEqual(4, indexOf_char(haystack, 'o'));
}

test "indexOf" {
    const testing = std.testing;
    try testing.expect(indexOf_char("hello", ' ') == null);
    try testing.expectEqual(@as(usize, 2), indexOf_char("hi lo", ' ').?);
}

test "indexOf_any_char" {
    const testing = std.testing;
    const haystack = "one two three four five six seven eight nine ten eleven";
    try testing.expectEqual(@as(?usize, 2), indexOfAny(haystack, "three")); // Finds 't' in "two"
    try testing.expectEqual(@as(?usize, 26), indexOfAny(haystack, "xyz")); // Not found
    try testing.expectEqual(@as(?usize, 0), indexOfAny(haystack, "four")); // Finds 'f' in "four"
}

test "decode_utf8_to_utf32 - Cyrillic string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "Привет";
    const expected = [_]u32{ 1055, 1088, 1080, 1074, 1077, 1090 }; // Unicode for "Привет"
    const output = try allocator.alloc(u32, utf32_len_from_utf8(input));
    defer allocator.free(output);

    const result = try decode_utf8_to_utf32(input, output);
    try testing.expectEqual(expected.len, result.len);
    for (expected, result) |exp, res| {
        try testing.expectEqual(exp, res);
    }
}

test "decode_utf8_to_utf32 - Emoji" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "😀";
    const expected = [_]u32{128512}; // Unicode  😊
    const output = try allocator.alloc(u32, utf32_len_from_utf8(input));
    defer allocator.free(output);

    const result = try decode_utf8_to_utf32(input, output);
    try testing.expectEqual(expected.len, result.len);
    try testing.expectEqual(expected[0], result[0]);
}

test " maxLen" {
    const testing = std.testing;
    const len = maxLen("aGVsbG8gd29ybGQ=");
    try testing.expectEqual(11, len);
}

test "decode_utf8_to_utf32 - ASCII string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const input = "Hello";
    const expected = [_]u32{ 72, 101, 108, 108, 111 }; // Unicode for "Hello"
    const output = try allocator.alloc(u32, utf32_len_from_utf8(input));
    defer allocator.free(output);

    const result = try decode_utf8_to_utf32(input, output);
    try testing.expectEqual(expected.len, result.len);
    for (expected, result) |exp, res| {
        try testing.expectEqual(exp, res);
    }
}

test "base64 decode" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const input = "SGVsbG8=";
    const len = maxLen(input);
    const output = try allocator.alloc(u8, len);
    defer allocator.free(output);
    const str = try decode_base64(input, output);
    try testing.expectEqualStrings("Hello", str);
}
//========================// *debug options //====================
pub const isDebug = std.builtin.Mode.Debug == builtin.mode;
pub const isRelease = std.builtin.Mode.Debug != builtin.mode and !isTest;
pub const isTest = builtin.is_test;
pub const allow_assert = isDebug or isTest or std.builtin.OptimizeMode.ReleaseSafe == builtin.mode;
//========================// *debug options //====================

pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
}

pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
}

/// Scans for:
/// - " "
/// - Non-ASCII characters (which implicitly include `\n`, `\r`, '\t')
pub fn indexOfSpaceOrNewlineOrNonASCII(haystack: []const u8) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = simd_index_of_space_or_newline_or_non_ascii(
        haystack.ptr,
        haystack.len,
    );

    return if (result == haystack.len) null else result;
}

/// Checks if the string contains any newlines, non-ASCII characters, or quotes
pub fn containsNewlineOrNonASCIIOrQuote(text: []const u8) bool {
    if (text.len == 0) {
        return false;
    }

    return simd_contains_newline_or_non_ascii_or_quote(
        text.ptr,
        text.len,
    );
}

fn getVectorWidth() comptime_int {
    const target = builtin.target;
    const cpu = builtin.cpu;
    const arch = target.cpu.arch;

    if (arch.isX86()) {
        if (cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512f))) {
            return 64; // 512
        } else if (cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
            return 32; // 256
        } else if (cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.sse))) {
            return 16; // 128
        }
    } else if (arch.isAArch64() and cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon))) {
        return 16; // 128  (NEON)
    } else if (arch.isWasm() and cpu.features.isEnabled(@intFromEnum(std.Target.wasm.Feature.simd128))) {
        return 16; // 128  (WASM SIMD)
    }

    return 0;
}
//only for u8 slices
pub fn compare(a: []const u8, b: []const u8) bool {
    return simd_compare(a.ptr, a.len, b.ptr, b.len);
}

test "compare-2" {
    try std.testing.expect(compare("abcd", "abcd"));

    try std.testing.expect(compare("abc", "abc"));
    try std.testing.expect(!compare("abc", "abcd"));

    try std.testing.expect(compare("abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc", "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc"));
    try std.testing.expect(!compare("abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc", "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvca"));
}

test "compare" {
    const testing = std.testing;
    try testing.expect(compare("hello", "hello"));
    try testing.expect(!compare("hello", "world"));
    try testing.expect(!compare("hello", "hell"));
}

pub fn copyBytes(comptime T: type, dest: []T, source: []const T) void {
    if (comptime isDebug) {
        if (source.len > dest.len) return; // Safety check
    }
    simd_copy_bytes(source.ptr, dest.ptr, source.len * @sizeOf(T));
}

test "copyBytes" {
    const testing = std.testing;
    const src = "hello";
    var dst: [5]u8 = undefined;
    copyBytes(u8, dst[0..], src);
    try testing.expectEqualStrings("hello", &dst);
}

pub fn toUpper(text: []u8) void {
    simd_to_upper(text.ptr, text.len);
}

test "toUpper" {
    const testing = std.testing;
    const text = "hello world";
    var buf: [11]u8 = undefined;
    copyBytes(u8, buf[0..], text);
    toUpper(&buf);
    try testing.expectEqualStrings("HELLO WORLD", &buf);
}

pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    comptime if (@sizeOf(T) == 0) {
        return a.len == b.len;
    };
    const block_size = getVectorWidth() / @sizeOf(T);
    if (block_size == 0 or a.len < 16) {
        return std.mem.eql(T, a, b);
    }
    const Vector = @Vector(block_size, T);
    var index: usize = 0;

    while (index + block_size <= a.len) : (index += block_size) {
        const av: Vector = a[index..][0..block_size].*;
        const bv: Vector = b[index..][0..block_size].*;
        if (!@reduce(.And, av == bv)) return false;
    }
    return std.mem.eql(T, a[index..], b[index..]);
}

test "eql-2" {
    try std.testing.expect(eql(u8, "abcd", "abcd"));

    try std.testing.expect(eql(u8, "abc", "abc"));
    try std.testing.expect(!eql(u8, "abc", "abcd"));

    try std.testing.expect(eql(u8, "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc", "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc"));
    try std.testing.expect(!eql(u8, "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvc", "abcdfty78uhgfdxsedrtyghvfxdzesr80hBRUHugyt799t8oguvhckdi9rtgvca"));
}

test "eql - u8 equal strings" {
    const testing = std.testing;
    const a = "hello world";
    const b = "hello world";
    try testing.expect(eql(u8, a, b));
}

test "eql - u8 different strings" {
    const testing = std.testing;
    const a = "hello world";
    const b = "hello earth";
    try testing.expect(!eql(u8, a, b));
}

test "eql - bool different arrays" {
    const testing = std.testing;
    const a = [_]bool{ true, false, true };
    const b = [_]bool{ true, true, true };
    try testing.expect(!eql(bool, a[0..], b[0..]));
}

test "eql - f32 equal arrays" {
    const testing = std.testing;
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    try testing.expect(eql(f32, a[0..], b[0..]));
}

test "eql - u32 equal arrays" {
    const testing = std.testing;
    const a = [_]u32{ 1, 2, 3, 4, 5 };
    const b = [_]u32{ 1, 2, 3, 4, 5 };
    try testing.expect(eql(u32, a[0..], b[0..]));
}

test "eql - u32 different arrays" {
    const testing = std.testing;
    const a = [_]u32{ 1, 2, 3, 4, 5 };
    const b = [_]u32{ 1, 2, 3, 4, 6 };
    try testing.expect(!eql(u32, a[0..], b[0..]));
}

test "eql - empty slices" {
    const testing = std.testing;
    const a = [_]u8{};
    const b = [_]u8{};
    try testing.expect(eql(u8, a[0..], b[0..]));
}

test "eql - different lengths" {
    const testing = std.testing;
    const a = "hello";
    const b = "hello world";
    try testing.expect(!eql(u8, a, b));
}

test "eql - large type (u64)" {
    const testing = std.testing;
    const a = [_]u64{ 1, 2, 3, 4 };
    const b = [_]u64{ 1, 2, 3, 4 };
    try testing.expect(eql(u64, a[0..], b[0..]));
}

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;

extern "c" fn simd_validate_ascii(input: [*]const u8, len: usize) bool;
extern "c" fn simd_validate_utf8(input: [*]const u8, len: usize) bool;

extern "c" fn simd_base64_max_length(input: [*]const u8, len: usize) usize;
extern "c" fn simd_base64_decode(input: [*]const u8, len: usize, output: [*]u8) isize;
extern "c" fn simd_convert_utf8_to_utf32(input: [*]const u8, len: usize, utf32_output: [*]u32) usize;
extern "c" fn simd_utf32_len_from_utf8(input: [*]const u8, len: usize) usize;
extern "c" fn simd_convert_utf32_to_utf8(
    input: [*c]const u32,
    len: usize,
    output: [*]u8,
) usize;
// extern "c" fn simd_compare(a: [*]const u8, b: [*]const u8, len: usize) bool;
extern "c" fn simd_index_of_char(
    haystack: [*]const u8,
    haystack_len: usize,
    needle: u8,
) usize;

extern "c" fn simd_index_of_any_char(
    text: [*]const u8,
    text_len: usize,
    chars: [*]const u8,
    chars_len: usize,
) usize;

extern "c" fn simd_detect_encodings(input: [*]const u8, len: usize) c_int;
extern "c" fn simd_count_utf8(input: [*]const u8, len: usize) usize;
extern "c" fn simd_compare(a: [*]const u8, a_len: usize, b: [*]const u8, b_len: usize) bool;
extern "c" fn simd_copy_bytes(src: [*]const u8, dst: [*]u8, len: usize) void;

extern "c" fn simd_to_upper(text: [*]u8, len: usize) void;
extern "c" fn simd_index_of_space_or_newline_or_non_ascii(
    input: [*]const u8,
    len: usize,
) usize;
extern "c" fn simd_contains_newline_or_non_ascii_or_quote(
    input: [*]const u8,
    len: usize,
) bool;
