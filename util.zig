const std = @import("std");
const builtin = @import("builtin");

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

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;
