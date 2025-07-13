const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;
const Buf = @import("pixbuf.zig");
const cache_pixman = @import("pixman_cache.zig");

const fcft = @cImport({
    @cInclude("fcft/stride.h");
    @cInclude("fcft/fcft.h");
});

pub const XcbftError = error{
    FcftInitFailed,
    FontLoadFailed,
    MemoryAllocationFailed,
    XrmDatabaseError,
    PictureCreationFailed,
    OutOfMemory,
    XcbConnectionError,
    XcbGeometryError,
    XcbImageError,
};

var font_name_buffer: [1][*c]const u8 = undefined;

pub const RenderFont = struct {
    conn: *c.xcb_connection_t,
    font: *fcft.fcft_font,
    // glyph: RasterizedGlyph,
    allocator: Allocator,
    dpi: f64,

    const Self = @This();

    pub fn init(
        conn: *c.xcb_connection_t,
        allocator: Allocator,
        comptime fontquery: [:0]const u8,
    ) !Self {
        if (c.xcb_connection_has_error(conn) != 0) {
            std.log.err("cannot connect XCB", .{});
            return XcbftError.XcbConnectionError;
        }

        if (!fcft.fcft_init(fcft.FCFT_LOG_COLORIZE_ALWAYS, false, fcft.FCFT_LOG_CLASS_ERROR)) {
            std.log.err("cannot create fcft", .{});
            return XcbftError.FcftInitFailed;
        }

        if (!fcft.fcft_set_scaling_filter(fcft.FCFT_SCALING_FILTER_LANCZOS3)) {
            std.log.err("scailing filter failed", .{});
            return XcbftError.FcftInitFailed;
        }

        font_name_buffer[0] = fontquery.ptr;

        const font = fcft.fcft_from_name(
            1,
            &font_name_buffer,
            null,
        ) orelse {
            std.log.err("Failed to load font: {s}", .{fontquery});
            return XcbftError.FontLoadFailed;
        };
        const dpi = try getDpi(conn);
        fcft.fcft_set_emoji_presentation(font, fcft.FCFT_EMOJI_PRESENTATION_DEFAULT);

        return .{
            .conn = conn,
            .font = font,
            .allocator = allocator,
            .dpi = dpi,
        };
    }

    pub fn deinit(self: *Self) void {
        fcft.fcft_destroy(self.font);
    }

    pub inline fn draw_char(
        self: *Self,
        buf: *Buf.Buf,
        char: u32,
        x: i16,
        y: i16,
        color: u32,
    ) !i16 {
        const g = fcft.fcft_rasterize_char_utf32(self.font, char, fcft.FCFT_SUBPIXEL_DEFAULT) orelse {
            return 0;
        };

        const format = c.pixman_image_get_format(@ptrCast(g.*.pix));

        if (format == c.PIXMAN_a8r8g8b8) {
            c.pixman_image_composite32(
                c.PIXMAN_OP_OVER,
                @ptrCast(g.*.pix),
                null,
                buf.pixman_image,
                0,
                0,
                0,
                0,
                try std.math.add(i16, x, @intCast(g.*.x)),
                try std.math.add(i16, @intCast(self.font.ascent), y) - @as(i16, @intCast(g.*.y)),
                @intCast(g.*.width),
                @intCast(g.*.height),
            );
        } else {
            const color_img = try cache_pixman.pixmanImageCreateSolidFillCached(color);
            c.pixman_image_composite32(
                c.PIXMAN_OP_OVER,
                color_img,
                @ptrCast(g.*.pix),
                buf.pixman_image,
                0,
                0,
                0,
                0,
                try std.math.add(i16, x, @intCast(g.*.x)),
                try std.math.add(i16, @intCast(self.font.ascent), y) - @as(i16, @intCast(g.*.y)),
                @intCast(g.*.width),
                @intCast(g.*.height),
            );
        }
        return @intCast(g.*.advance.x);
    }

    pub fn drawText(
        self: *Self,
        buf: *Buf.Buf,
        text: []const u32,
        x: i16,
        y: i16,
        color: u32,
    ) !void {
        var width: i32 = 0;
        var prev_char: ?u32 = null;

        for (text) |cp| {
            var kern: i32 = 0;
            if (prev_char) |prev| {
                var x_kern: c_long = 0;
                if (fcft.fcft_kerning(self.font, prev, cp, &x_kern, null)) {
                    kern = @intCast(x_kern);
                }
            }

            const advance = try self.draw_char(buf, cp, @intCast(@as(i32, @intCast(x)) + width + kern), y, color);
            width += kern + advance;
            prev_char = cp;
        }

        try buf.draw();
    }
    // pub fn drawText(
    //     self: *Self,
    //     buf: *Buf.Buf,
    //     text: []const u32,
    //     x: i16,
    //     y: i16,
    //     color: *c.pixman_color_t,
    // ) !void {
    //     const color_img = c.pixman_image_create_solid_fill(
    //         color,
    //     );
    //     defer _ = c.pixman_image_unref(color_img);
    //     if (color_img == null) {
    //         std.log.err("Failed to create fg", .{});
    //         return error.FgPixmanFailed;
    //     }
    //
    //     // Rasterize text
    //     var rasterized = try rasterizeText(self.font, text, self.allocator);
    //     defer rasterized.deinit(self.allocator);
    //
    //     // Render to buffer
    //     rasterized.renderToBuf(buf, x, y, color_img);
    //
    //     // Draw to screen
    //     try buf.draw();
    // }
};

pub inline fn color_to_uint32(comptime T: type, rgb: T) u32 {
    const r: u8 = @intCast(rgb.red >> 8);
    const g: u8 = @intCast(rgb.green >> 8);
    const b: u8 = @intCast(rgb.blue >> 8);
    const a: u8 = @intCast(rgb.alpha >> 8);
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | (@as(u32, b));
}

pub fn getDpi(conn: *c.xcb_connection_t) XcbftError!f64 {
    if (c.xcb_connection_has_error(conn) != 0) {
        std.log.err("XCB connection error", .{});
        return XcbftError.XrmDatabaseError;
    }

    var dpi: f64 = 0;

    // Try XRM database
    const xrm_db = c.xcb_xrm_database_from_default(conn);
    if (xrm_db != null) {
        defer c.xcb_xrm_database_free(xrm_db);
        const ret = c.xcb_xrm_resource_get_long(xrm_db, "Xft.dpi", null, @ptrCast(&dpi));
        if (ret >= 0 and dpi > 0) {
            return dpi;
        } else {
            std.log.debug("XRM resource 'Xft.dpi' not found or invalid (ret={})", .{ret});
            // return 96.0;
        }
    } else {
        std.log.debug("XRM database unavailable", .{});
    }

    // Fallback to screen metrics
    const setup = c.xcb_get_setup(conn);
    if (setup == null) {
        std.log.err("Failed to get XCB setup", .{});
        return XcbftError.XrmDatabaseError;
    }
    dpi = 0;

    var iter = c.xcb_setup_roots_iterator(setup);
    while (iter.rem > 0) {
        if (iter.data != null) {
            const screen = iter.data.*;
            const width_mm = @as(f64, @floatFromInt(screen.width_in_millimeters));
            const width_pixels = @as(f64, @floatFromInt(screen.width_in_pixels));
            if (width_mm > 0 and width_pixels > 0) { // Validate both dimensions
                const xres = (width_pixels * 25.4) / width_mm;
                if (xres > dpi and xres < 1000.0) { // Cap DPI to avoid outliers
                    dpi = xres;
                }
            } else {
                std.log.debug("Invalid screen metrics: width_mm={}, width_pixels={}", .{ width_mm, width_pixels });
            }
        }
        c.xcb_screen_next(&iter);
    }

    // Default DPI if all else fails
    if (dpi == 0) {
        dpi = 96.0;
        std.log.debug("Using default DPI: {}", .{dpi});
    }

    return dpi;
}
