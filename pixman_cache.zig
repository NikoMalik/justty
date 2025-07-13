const std = @import("std");
const cc = @import("c.zig");

const CACHE_SIZE = 32;

inline fn red(c: u32) u8 {
    return @as(u8, @intCast((c >> 16) & 0xFF));
}

inline fn green(c: u32) u8 {
    return @as(u8, @intCast((c >> 8) & 0xFF));
}

inline fn blue(c: u32) u8 {
    return @as(u8, @intCast(c & 0xFF));
}

const CacheEntry = struct {
    color: u32,
    image: ?*cc.pixman_image_t,
};

var g_next_slot: usize = 0;
var g_cached: [CACHE_SIZE]CacheEntry = undefined;

pub fn pixmanImageCreateSolidFillCached(c: u32) !*cc.pixman_image_t {
    for (g_cached, 0..) |entry, i| {
        if (entry.image != null and entry.color == c) {
            std.log.debug("Cache hit for color 0x{x} at slot {d}", .{ c, i });
            return entry.image.?;
        }
    }

    const slot = g_next_slot;
    g_next_slot = (g_next_slot + 1) % CACHE_SIZE;

    if (g_cached[slot].image) |old_image| {
        _ = cc.pixman_image_unref(old_image);
        g_cached[slot].image = null;
        std.log.debug("Freed old image at slot {d}", .{slot});
    }

    const color = cc.pixman_color_t{
        .red = @as(u16, red(c)) * 257,
        .green = @as(u16, green(c)) * 257,
        .blue = @as(u16, blue(c)) * 257,
        .alpha = 0xFFFF,
    };

    const image = cc.pixman_image_create_solid_fill(&color) orelse {
        std.log.err("Failed to create pixman image for color 0x{x}", .{c});
        return error.PixmanImageCreateFailed;
    };

    g_cached[slot] = CacheEntry{
        .color = c,
        .image = image,
    };

    std.log.debug("Created new image for color 0x{x} at slot {d}", .{ c, slot });
    return image;
}

pub fn deinitColorCache() void {
    for (g_cached) |*entry| {
        if (entry.image) |img| {
            _ = cc.pixman_image_unref(img);
            entry.image = null;
        }
    }
    g_next_slot = 0;
    std.log.debug("Color cache cleared", .{});
}
