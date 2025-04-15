const std = @import("std");

pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
}

pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
}

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;
