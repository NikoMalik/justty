const std = @import("std");
const builtin = @import("builtin");
const unicode = std.unicode;
const assert = std.debug.assert;
const has_avx2 = std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

extern fn asm_memcpy(dest: *anyopaque, src: *const anyopaque, n: usize) callconv(.C) *anyopaque;
extern fn asm_memmove(dest: *anyopaque, src: *const anyopaque, n: usize) callconv(.C) *anyopaque;
extern fn __folly_memcpy(dest: *anyopaque, src: *const anyopaque, n: usize) *anyopaque;
extern fn __folly_memset(dest: *anyopaque, ch: c_int, size: usize) void;

pub inline fn set(comptime T: type, dest: []T, value: u8) void {
    if (comptime has_avx2) {
        __folly_memset(
            @ptrCast(dest.ptr),
            @intCast(value),
            dest.len * @sizeOf(T),
        );
    } else {
        @memset(dest, value);
    }
}

pub inline fn folly_move(comptime T: type, dest: []T, source: []const T) void {
    _ = __folly_memcpy(
        dest.ptr,
        source.ptr,
        source.len * @sizeOf(T),
    );
}

pub inline fn move_asm(comptime T: type, dest: []T, source: []const T) void {
    _ = asm_memmove(
        @ptrCast(dest.ptr),
        @ptrCast(source.ptr),
        dest.len * @sizeOf(T),
    );
}

pub inline fn copy_asm(comptime T: type, dest: []T, source: []const T) void {
    _ = asm_memcpy(
        @ptrCast(dest.ptr),
        @ptrCast(source.ptr),
        dest.len * @sizeOf(T),
    );
}

pub fn maxLen(input: []const u8) usize {
    return simd_base64_max_length(input.ptr, input.len);
}

pub inline fn safeClamp(val: anytype, lower: anytype, upper: anytype) @TypeOf(val, lower, upper) {
    return std.math.clamp(val, lower, upper);
}

pub fn comptime_slice(comptime slice: anytype, comptime len: usize) []const @TypeOf(slice[0]) {
    return &@as([len]@TypeOf(slice[0]), slice[0..len].*);
}
pub const SizePrecision = enum { exact, inexact };

pub inline fn disjoint_slices(comptime A: type, comptime B: type, a: []const A, b: []const B) bool {
    return @intFromPtr(a.ptr) + a.len * @sizeOf(A) <= @intFromPtr(b.ptr) or
        @intFromPtr(b.ptr) + b.len * @sizeOf(B) <= @intFromPtr(a.ptr);
}

fn has_pointers(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Pointer => return true,
        else => return true,

        .Bool, .Int, .Enum => return false,

        .Array => |info| return comptime has_pointers(info.child),
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (comptime has_pointers(field.type)) return true;
            }
            return false;
        },
    }
}

pub fn equal_bytes(comptime T: type, a: *const T, b: *const T) bool {
    assert(@inComptime());
    comptime assert(!has_pointers(T));
    comptime assert(@sizeOf(T) * 8 == @bitSizeOf(T));

    const Word = comptime for (.{ u64, u32, u16, u8 }) |Word| {
        if (@alignOf(T) >= @alignOf(Word) and @sizeOf(T) % @sizeOf(Word) == 0) break Word;
    } else unreachable;

    const a_words = std.mem.bytesAsSlice(Word, std.mem.asBytes(a));
    const b_words = std.mem.bytesAsSlice(Word, std.mem.asBytes(b));
    comptime assert(a_words.len == b_words.len);

    var total: Word = 0;
    for (a_words, b_words) |a_word, b_word| {
        total |= a_word ^ b_word;
    }

    return total == 0;
}

//---------------------------------------------------------------
// DEBUG
pub const backend_can_print = !(builtin.zig_backend == .stage2_spirv64 or builtin.zig_backend == .stage2_riscv64);

fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (backend_can_print) {
        std.debug.print(fmt, args);
    }
}
fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i..][0..nl]);
    }
    print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}
fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    print("{s}\n", .{line});
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(u8, source[0..indicator_index], '\n')) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(u8, source[indicator_index..], '\n')) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    for (line_begin_index..indicator_index) |_|
        print(" ", .{});
    if (indicator_index >= source.len)
        print("^ (end of string)\n", .{})
    else
        print("^ ('\\x{x:0>2}')\n", .{source[indicator_index]});
}

pub fn expectContainsStrings(expected: []const u8, actual: []const u8) !void {
    if (indexOf_any_char(expected, actual)) |index| {
        print("\n====== expected this output: =========\n", .{});
        printWithVisibleNewlines(expected);
        print("\n======== instead found this: =========\n", .{});
        printWithVisibleNewlines(actual);
        print("\n======================================\n", .{});
        var diff_line_number: usize = 1;
        for (expected[0..index]) |value| {
            if (value == '\n') diff_line_number += 1;
        }
        print("First difference occurs on line {d}:\n", .{diff_line_number});

        print("expected:\n", .{});
        printIndicatorLine(expected, index);

        print("found:\n", .{});
        printIndicatorLine(actual, index);
    }
}

//---------------------------------------------------------------

pub inline fn safeLongToI16(value: c_long) !i16 {
    return if (value > std.math.maxInt(i16))
        error.Overflow
    else if (value < std.math.minInt(i16))
        error.Underflow
    else
        @intCast(value);
}

pub inline fn safeCast(c_ulong_val: c_ulong) !i16 {
    return if (c_ulong_val > @as(c_ulong, @intCast(std.math.maxInt(i16))))
        error.Overflow
    else if (c_ulong_val < @as(c_ulong, @intCast(std.math.minInt(i16))))
        error.Underflow
    else
        @intCast(c_ulong_val);
}

pub fn isAscii(input: []const u8) bool {
    var remain = input;
    if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
        while (remain.len > vector_len) {
            const chunk: @Vector(vector_len, u8) = remain[0..vector_len].*;
            if (@reduce(.Max, chunk) < 128) {
                return true;
            }
            remain = remain[vector_len..];
        }
    }
    for (remain) |c| {
        if (c < 128) {
            return true;
        }
    }
    return false;
}

test "isAscii with all ASCII characters" {
    const testing = std.testing;
    const input = "Hello, World! 123";
    try testing.expect(isAscii(input) == true); // All characters are ASCII (< 128)
}

test "isAscii with mixed ASCII and non-ASCII characters" {
    const testing = std.testing;

    const input = "Hello, 世界!";
    try testing.expect(isAscii(input) == true); // Contains ASCII characters (e.g., 'H', 'e')
}

test "isAscii with all non-ASCII characters" {
    const testing = std.testing;

    const input = "世界你好"; // All characters >= 128
    try testing.expect(isAscii(input) == false); // No ASCII characters
}

test "isAscii with single ASCII character" {
    const testing = std.testing;

    try testing.expect(isAscii("A") == true); // Single ASCII character
}

test "isAscii with single non-ASCII character" {
    const testing = std.testing;

    try testing.expect(isAscii("世") == false); // Single non-ASCII character
}

test "isAscii with boundary ASCII value (127)" {
    const testing = std.testing;

    try testing.expect(isAscii("\x7F") == true); // 127 is the highest ASCII value
}

test "isAscii with boundary non-ASCII value (128)" {
    const testing = std.testing;

    try testing.expect(isAscii("\x80") == false); // 128 is non-ASCII
}

test "isAscii with long ASCII input" {
    const testing = std.testing;

    const input = "a" ** 100; // 100 ASCII characters
    try testing.expect(isAscii(input) == true);
}

pub inline fn maskbase(m: u32) i16 {
    if (m == 0) return 0;
    var i: i16 = 0;
    var mask = m;
    while (mask & 1 == 0) {
        mask >>= 1;
        i += 1;
    }
    return i;
}

pub inline fn masklen(m: u64) i16 {
    var y = (m >> 1) & 0x3333333333333333;
    y = m - y - ((y >> 1) & 0x3333333333333333);
    y = (y + (y >> 3)) & 0x0707070707070707;
    return @as(i16, @intCast(y % 63));
}

pub inline fn getCodepointLength(comptime T: type, cp: T) u3 {
    return switch (cp) {
        0x00000...0x00007F => @as(u3, 1),
        0x00080...0x0007FF => @as(u3, 2),
        0x00800...0x00FFFF => @as(u3, 3),
        0x10000...0x10FFFF => @as(u3, 4),
        else => @as(u3, 0),
    };
}

pub inline fn utf8Encode(comptime T: type, cp: T, out: []u8) u3 {
    const length = getCodepointLength(T, cp);

    switch (length) {
        1 => {
            out[0] = @truncate(cp);
        },

        2 => {
            out[0] = @truncate(0xC0 | (cp >> 6));
            out[1] = @truncate(0x80 | (cp & 0x3F));
        },

        3 => {
            out[0] = @truncate(0xE0 | (cp >> 12));
            out[1] = @truncate(0x80 | ((cp >> 6) & 0x3F));
            out[2] = @truncate(0x80 | (cp & 0x3F));
        },

        4 => {
            out[0] = @truncate(0xF0 | (cp >> 18));
            out[1] = @truncate(0x80 | ((cp >> 12) & 0x3F));
            out[2] = @truncate(0x80 | ((cp >> 6) & 0x3F));
            out[3] = @truncate(0x80 | (cp & 0x3F));
        },

        else => unreachable,
    }

    return length;
}
/// Returns `true` if the character is printable
/// (`A-Z`, `a-z`, `0-9`, `punctuation marks`, `space`).
pub inline fn isPrintable(c: u8) bool {
    return switch (c) {
        ' '...'~' => true,
        else => false,
    };
}

/// Returns true if the character is a control character
/// (`ASCII 0x00-0x1F or 0x7F`).
pub inline fn isControl(c: u8) bool {
    return (c <= 0x1F) or (c == 0x7F);
}

pub fn utf8_validate_pos(input: []const u8) ?usize {
    var i: usize = 0;
    while (i < input.len) {
        const len = unicode.utf8ByteSequenceLength(input[i]) catch return i;
        if (i + len > input.len) return i;
        if (!utf8_validate(input[i .. i + len])) return i;
        i += len;
    }
    return i;
}

pub inline fn utf8_validate(input: []const u8) bool {
    return simd_validate_utf8(input.ptr, input.len);
}

/// find begin CSI escape (\x1B[).
/// return index of begin or null, if not found.
pub inline fn indexOfCsiStart(input: []const u8) ?usize {
    const result = simd_index_of_csi_start(input.ptr, input.len);
    return if (result == input.len) null else result;
}
test "indexOfCsiStart" {
    const testing = std.testing;
    const input = "\x1B[31mHello";
    try testing.expectEqual(@as(usize, 0), indexOfCsiStart(input).?);
    try testing.expectEqual(null, indexOfCsiStart("No CSI"));
    try testing.expectEqual(@as(usize, 5), indexOfCsiStart("Hello\x1B[m").?);
}

pub inline fn lastIndex(input: []const u8, v: u8) ?usize {
    const result = simd_last_index_of_byte(input.ptr, input.len, v);
    if (result == 0) return null;
    return if (result == input.len) null else result;
}

test "lastIndex finds last occurrence of byte" {
    const input = [_]u8{ 1, 2, 3, 2, 4 };
    try std.testing.expectEqual(@as(?usize, 3), lastIndex(&input, 2));
}

test "last index find ::" {
    const input = "s::";
    try std.testing.expectEqual(@as(?usize, 2), lastIndex(input, ':'));
}

test "lastIndex returns null if byte not found" {
    const input = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(?usize, null), lastIndex(&input, 5));
}

test "lastIndex handles empty slice" {
    const input = [_]u8{};
    try std.testing.expectEqual(@as(?usize, null), lastIndex(&input, 1));
}

/// extract full CSI escape, begin from index.
/// return slice sequence  or null, if csi incorrect.
pub fn extractCsiSequence(input: []const u8, start: usize) ?[]const u8 {
    var end: usize = undefined;
    const len = simd_extract_csi_sequence(input.ptr, input.len, start, &end);
    return if (len > 0) input[start..end] else null;
}

test "extractCsiSequence" {
    const testing = std.testing;
    const input = "\x1B[31mHello";
    if (indexOfCsiStart(input)) |csi| {
        try testing.expectEqualStrings("\x1B[31m", extractCsiSequence(input, csi).?);
    } else {
        std.log.err("Expected CSI start in input", .{});
    }

    try testing.expectEqual(null, extractCsiSequence("No CSI", 0));
    try testing.expectEqual(null, extractCsiSequence("\x1B[123", 0));
    try testing.expectEqualStrings("\x1B[m", extractCsiSequence("Hello\x1B[m", 5).?);
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

pub fn decode_utf32_to_utf8(input: []const u32, output: []const u8) ![]const u8 {
    const res = simd_convert_utf32_to_utf8(input.ptr, utf32_len_from_utf8(input), output.ptr);
    if (res == 0) return error.Utf32DecodeFailed;
    return output[0..res];
}

pub fn detectEncodings(input: []const u8) u32 {
    return @bitCast(simd_detect_encodings(input.ptr, input.len));
}

test "detectEncodings" {
    const testing = std.testing;
    const utf8 = "Hello 😊";
    const utf16le = "\x48\x00\x65\x00\x6C\x00\x6C\x00\x6F\x00"; // "Hello" in UTF-16LE
    // UTF-32LE check ("Hello" + emoj 😊)
    // H(0x48 0x00 0x00 0x00) e(0x65 0x00...) l l o 😊(0x0A 0xF6 0x01 0x00)
    const utf32le = "\x48\x00\x00\x00" ++
        "\x65\x00\x00\x00" ++
        "\x6C\x00\x00\x00" ++
        "\x6C\x00\x00\x00" ++
        "\x6F\x00\x00\x00" ++
        "\x0A\xF6\x01\x00";
    try testing.expect(detectEncodings(utf8) & 0x1 != 0); // UTF-8 flag
    try testing.expect(detectEncodings(utf16le) & 0x2 != 0); // UTF-16LE flag
    try testing.expect(detectEncodings(utf32le) & 0x3 != 0); // UTF-32LE flag
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

pub inline fn containsChar(input: []const u8, char: u8) bool {
    return indexOf_char(input, char) != null;
}

pub fn containsCharT(comptime T: type, input: []const T, char: T) bool {
    return switch (T) {
        u8 => containsChar(input, char),
        u16 => std.mem.indexOfScalar(u16, input, char) != null,
        u32 => std.mem.indexOfScalar(u32, input, char) != null,
        else => @compileError("invalid type"),
    };
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
    if (comptime !has_avx2) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    }
    if (comptime has_avx2) {
        _ = __folly_memcpy(
            dest.ptr,
            source.ptr,
            source.len * @sizeOf(T),
        );
    }
}

// Copy Backwards
pub inline fn moveSimd(comptime T: type, dest: []T, source: []const T) void {
    const len = source.len;
    const src_ptr = @as([*]const u8, @ptrCast(source.ptr));
    const dst_ptr = @as([*]u8, @ptrCast(dest.ptr));
    const byte_len = len * @sizeOf(T);
    simd_move_bytes(src_ptr, dst_ptr, byte_len);
}

test "movesimd check" {
    const a = try std.testing.allocator.alloc(usize, 8);
    defer std.testing.allocator.free(a);

    for (a, 0..) |*v, i| v.* = i;
    moveSimd(usize, a[2..], a[0..6]);
    try std.testing.expect(std.mem.eql(usize, a, &.{ 0, 1, 0, 1, 2, 3, 4, 5 }));
}

test "folly_check" {
    const a = try std.testing.allocator.alloc(usize, 8);
    defer std.testing.allocator.free(a);

    for (a, 0..) |*v, i| v.* = i;
    folly_move(usize, a[0..6], a[2..]);
    try std.testing.expect(std.mem.eql(usize, a, &.{ 2, 3, 4, 5, 6, 7, 6, 7 }));
}

test "moveSimd" {
    const T = u32;
    var src = [_]T{ 1, 2, 3, 4, 5 };
    var dst = [_]T{ 0, 0, 0, 0, 0 };

    moveSimd(T, dst[0..], src[0..]);
    try std.testing.expectEqualSlices(T, src[0..], dst[0..]);

    src = [_]T{ 1, 2, 3, 4, 5 };
    moveSimd(T, src[2..4], src[0..2]);
    try std.testing.expectEqualSlices(T, &[_]T{ 1, 2, 1, 2, 5 }, src[0..]);

    const empty: []T = &.{};
    moveSimd(T, empty, empty);
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

pub inline fn copyBytes(comptime T: type, dest: []T, source: []const T) void {
    simd_copy_bytes(source.ptr, dest.ptr, source.len * @sizeOf(T));
}

pub inline fn moveBytes(dst: []u8, src: []const u8) void {
    if (comptime isDebug) {
        if (src.len > dst.len) return;
    }
    simd_move_bytes(src.ptr, dst.ptr, src.len * @sizeOf(u8));
}

test "folly_move and folly_set: benchmark" {
    const buffer_size = 10242;
    var src: [buffer_size]u8 = undefined;
    var dst: [buffer_size]u8 = undefined;
    const iterations = 1000;

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    for (&src) |*byte| {
        byte.* = random.int(u8);
    }

    //@follyset
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        set(u8, dst[0..], 0xAA);
    }
    const set_elapsed = timer.read();
    std.debug.print("folly_set bench: {} ns per iteration\n", .{set_elapsed / iterations});

    //  @memset
    timer.reset();
    for (0..iterations) |_| {
        @memset(dst[0..], 0xAA);
    }
    const std_set_elapsed = timer.read();
    std.debug.print("std @memset bench: {} ns per iteration\n", .{std_set_elapsed / iterations});
}

test "copy_simd: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        copyBytes(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("copy_simd bench: {} ns\n", .{elapsed / 1000});
}
test "memcpy: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        copy(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("memcpy bench: {} ns\n", .{elapsed / 1000});
}

test "memcpy_asm: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        copy_asm(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("memcpy asm bench: {} ns\n", .{elapsed / 1000});
}

test "folly_move_as copy: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        folly_move(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("copy folly bench: {} ns\n", .{elapsed / 1000});
}

test "@memcpy: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        @memcpy(&dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("memcpy zig: {} ns\n", .{elapsed / 1000});
}

test "memmove_bytes_glibc: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        move(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_glibc big: {} ns\n", .{elapsed / 1000});
}

test "move_bytes_folly_big: benchmark" {
    var src: [10242]u8 = undefined;
    var dst: [10242]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        folly_move(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_folly_big: {} ns\n", .{elapsed / 1000});
}

test "move_bytes_folly: benchmark" {
    var src: [1024]u8 = undefined;
    var dst: [1024]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        folly_move(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_folly: {} ns\n", .{elapsed / 1000});
}

test "move_bytes_asm: benchmark" {
    var src: [1024]u8 = undefined;
    var dst: [1024]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        move_asm(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_asm: {} ns\n", .{elapsed / 1000});
}

test "move_bytes: benchmark" {
    var src: [1024]u8 = undefined;
    var dst: [1024]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        moveSimd(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_simd: {} ns\n", .{elapsed / 1000});
}

test "memmove_bytes: benchmark" {
    var src: [1024]u8 = undefined;
    var dst: [1024]u8 = undefined;
    var timer = try std.time.Timer.start();
    for (0..1000) |_| {
        move(u8, &dst, &src);
    }
    const elapsed = timer.read();
    std.debug.print("move_bytes_glibc: {} ns\n", .{elapsed / 1000});
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

pub extern "c" fn simd_index_of_any_char(
    text: [*]const u8,
    text_len: usize,
    chars: [*]const u8,
    chars_len: usize,
) usize;

extern "c" fn simd_detect_encodings(input: [*]const u8, len: usize) c_int;
extern "c" fn simd_count_utf8(input: [*]const u8, len: usize) usize;
extern "c" fn simd_compare(a: [*]const u8, a_len: usize, b: [*]const u8, b_len: usize) bool;
pub extern "c" fn simd_copy_bytes(src: [*]const u8, dst: [*]u8, len: usize) void;
pub extern "c" fn simd_move_bytes(src: [*]const u8, dst: [*]u8, len: usize) void;

extern "c" fn simd_to_upper(text: [*]u8, len: usize) void;
extern "c" fn simd_index_of_space_or_newline_or_non_ascii(
    input: [*]const u8,
    len: usize,
) usize;
extern "c" fn simd_contains_newline_or_non_ascii_or_quote(
    input: [*]const u8,
    len: usize,
) bool;

extern "c" fn simd_index_of_csi_start(input: [*]const u8, len: usize) usize;
pub extern "c" fn simd_extract_csi_sequence(input: [*]const u8, len: usize, start: usize, end: *usize) usize;
extern "c" fn simd_parse_csi_params(
    csi: [*]const u8,
    len: usize,
    params: [*]i32,
    max_params: usize,
) usize;
extern "c" fn simd_is_valid_csi(input: [*]const u8, len: usize) bool;
extern "c" fn simd_count_utf8_in_csi(csi: [*]const u8, len: usize) usize;
extern "c" fn simd_last_index_of_byte(
    input: [*]const u8,
    len: usize,
    value: u8,
) usize;
