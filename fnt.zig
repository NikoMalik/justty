const std = @import("std");
const c = @import("c.zig");
const Allocator = std.mem.Allocator;
const Buf = @import("pixbuf.zig");

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

const RasterizedGlyph = struct {
    glyph: *fcft.fcft_glyph,
    x: i32, // Horizontal position
    kern: i32, // Kerning adjustment
};

const RasterizedText = struct {
    glyphs: []RasterizedGlyph,
    total_width: i32,
    total_height: i32,
    ascent: i32,

    fn renderToBuf(self: @This(), buf: *Buf.Buf, dx: i32, dy: i32, color_img: ?*c.pixman_image_t) void {
        var x: i32 = dx;
        const y: i32 = dy + self.ascent; // Adjust for baseline

        var clip_region: c.pixman_region32_t = undefined;
        c.pixman_region32_init_rect(
            &clip_region,
            0,
            0,
            @intCast(buf.width),
            @intCast(buf.height),
        );
        defer c.pixman_region32_fini(&clip_region);

        _ = c.pixman_image_set_clip_region32(buf.pixman_image, &clip_region);

        for (self.glyphs) |g| {
            const glyph = g.glyph;

            x += g.kern;
            const glyph_x = x + g.x;
            const glyph_y = y - glyph.y;

            if (glyph_x + @as(i32, @intCast(glyph.width)) < 0 or
                glyph_y + @as(i32, @intCast(glyph.height)) < 0 or
                glyph_x >= @as(i32, @intCast(buf.width)) or
                glyph_y >= @as(i32, @intCast(buf.height)))
            {
                x += glyph.advance.x;
                continue;
            }

            if (glyph.is_color_glyph) {
                // Render color glyph (e.g., emoji) directly
                c.pixman_image_composite32(
                    c.PIXMAN_OP_OVER,
                    @ptrCast(glyph.pix),
                    null,
                    buf.pixman_image,
                    0,
                    0,
                    0,
                    0,
                    glyph_x,
                    glyph_y,
                    @intCast(glyph.width),
                    @intCast(glyph.height),
                );
            } else if (color_img) |color| {
                // Render monochrome glyph with specified color
                c.pixman_image_composite32(
                    c.PIXMAN_OP_OVER,
                    color,
                    @ptrCast(glyph.pix),
                    buf.pixman_image,
                    0,
                    0,
                    0,
                    0,
                    glyph_x,
                    glyph_y,
                    @intCast(glyph.width),
                    @intCast(glyph.height),
                );
            }

            x += glyph.advance.x;
        }

        _ = c.pixman_image_set_clip_region32(buf.pixman_image, null);
    }
    fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.glyphs);
    }
};

pub fn rasterizeText(
    font: *fcft.fcft_font,
    text: []const u32,
    allocator: Allocator,
) !RasterizedText {
    var glyphs = std.ArrayList(RasterizedGlyph).init(allocator);
    defer glyphs.deinit();

    var x: i32 = 0;
    var total_height: i32 = 0;
    var total_width: i32 = 0;

    for (text, 0..) |codepoint, i| {
        const glyph = fcft.fcft_rasterize_char_utf32(font, codepoint, fcft.FCFT_SUBPIXEL_DEFAULT) orelse continue;

        var kern: i32 = 0;
        if (i > 0) {
            var x_kern: c_long = 0;
            if (fcft.fcft_kerning(font, text[i - 1], codepoint, &x_kern, null)) {
                kern = @intCast(x_kern);
            }
        }

        try glyphs.append(RasterizedGlyph{
            .glyph = @ptrCast(@constCast(glyph)),
            .x = x,
            .kern = kern,
        });

        x += kern + glyph.*.advance.x;
        total_width += kern + glyph.*.advance.x;
        total_height = @max(total_height, @as(u16, @intCast(glyph.*.height)));
    }

    return RasterizedText{
        .glyphs = try glyphs.toOwnedSlice(),
        .total_width = total_width,
        .total_height = total_height,
        .ascent = @intCast(font.ascent),
    };
}

pub const XRenderFont = struct {
    conn: *c.xcb_connection_t,
    font: *fcft.fcft_font,
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

        if (!fcft.fcft_init(fcft.FCFT_LOG_COLORIZE_AUTO, false, fcft.FCFT_LOG_CLASS_ERROR)) {
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
    pub fn drawText(
        self: *Self,
        buf: *Buf.Buf,
        text: []const u32,
        x: i16,
        y: i16,
        color: *c.pixman_color_t,
    ) !void {
        const color_img = c.pixman_image_create_solid_fill(
            color,
        );
        defer _ = c.pixman_image_unref(color_img);
        if (color_img == null) {
            std.log.err("Failed to create fg", .{});
            return error.FgPixmanFailed;
        }

        // Rasterize text
        var rasterized = try rasterizeText(self.font, text, self.allocator);
        defer rasterized.deinit(self.allocator);

        // Render to buffer
        rasterized.renderToBuf(buf, x, y, color_img);

        buf.clear(0xFF0000FF);

        // Draw to screen
        try buf.draw();
    }
};

pub inline fn xcb_color_to_uint32(rgb: c.xcb_render_color_t) u32 {
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
