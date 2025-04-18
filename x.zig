const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const justty = @import("justty.zig");
const font = @import("font.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

const Key = packed struct(u64) {
    key_sym: c.xcb_keysym_t,
    mode: u32,
};

const VisualData = struct {
    visual: *c.xcb_visualtype_t,
    visual_depth: u8,

    const Self = @This();

    pub fn init(screen: *c.xcb_screen_t) !Self {
        var depth_iter = c.xcb_screen_allowed_depths_iterator(screen);
        while (depth_iter.rem != 0) {
            if (depth_iter.data.*.depth == screen.*.root_depth) {
                var visual_iter = c.xcb_depth_visuals_iterator(depth_iter.data);
                while (visual_iter.rem != 0) {
                    if (visual_iter.data.*.visual_id == screen.*.root_visual) {
                        return Self{
                            .visual = visual_iter.data,
                            .visual_depth = depth_iter.data.*.depth,
                        };
                    }
                    c.xcb_visualtype_next(&visual_iter);
                }
            }
            c.xcb_depth_next(&depth_iter);
        }
        return error.NoMatchingVisual;
    }
};

const win_mode = union(enum(u32)) {
    MODE_VISIBLE = 1 << 0,
    MODE_FOCUSED = 1 << 1,
    MODE_APPKEYPAD = 1 << 2,
    MODE_MOUSEBTN = 1 << 3,
    MODE_MOUSEMOTION = 1 << 4,
    MODE_REVERSE = 1 << 5,
    MODE_KBDLOCK = 1 << 6,
    MODE_HIDE = 1 << 7,
    MODE_APPCURSOR = 1 << 8,
    MODE_MOUSESGR = 1 << 9,
    MODE_8BIT = 1 << 10,
    MODE_BLINK = 1 << 11,
    MODE_FBLINK = 1 << 12,
    MODE_FOCUS = 1 << 13,
    MODE_MOUSEX10 = 1 << 14,
    MODE_MOUSEMANY = 1 << 15,
    MODE_BRCKTPASTE = 1 << 16,
    MODE_NUMLOCK = 1 << 17,
    MODE_MOUSE = 1 << 3 | 1 << 4 | 1 << 14 | 1 << 15,
};

// Purely graphic info //
const TermWindow = struct {
    // window state/mode flags */
    mode: win_mode,
    // tty width and height */
    tw: u32,
    th: u32,
    // window width and height */
    w: u32,
    h: u32,
    // char height */
    ch: u32,
    // char width  */
    cw: u32,
    // cursor style */
    cursor: u32,
};

const Font = struct {
    face: font.Face,
    height: usize,
    width: usize,
    ascent: usize,
};
// Drawing Context
const DC = struct {
    col: [260]Color, // len: usize,
    font: Font,
    gc: c.xcb_gcontext_t,
};

const RenderColor = packed struct(u64) {
    /// Red color channel. */
    red: u16,
    // Green color channel. */
    green: u16,
    // Blue color channel. */
    blue: u16,
    // Alpha color channel. */
    alpha: u16,
};

const Color = packed struct(u96) {
    pixel: u32,
    color: RenderColor,
};

pub inline fn get_cursor(conn: *c.xcb_connection_t, name: [*c]const u8) c.xcb_cursor_t {
    var ctx: *c.xcb_cursor_context_t = undefined;
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;

    _ = c.xcb_cursor_context_new(conn, screen, &ctx);
    const cursor: c.xcb_cursor_t = c.xcb_cursor_load_cursor(ctx, name);
    _ = c.xcb_cursor_context_free(ctx);
    return cursor;
}

pub inline fn get_cmap_from_winattr(conn: *c.xcb_connection_t, wac: c.xcb_get_window_attributes_cookie_t) c.xcb_colormap_t {
    const reply: *c.xcb_get_window_attributes_reply_t = c.xcb_get_window_attributes_reply(conn, wac, null);
    const cmap: c.xcb_colormap_t = reply.colormap;
    std.c.free(reply);
    return cmap;
}

pub inline fn create_gc(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    win: c.xcb_window_t,
    fg: u32,
    bg: u32,
) c.xcb_gcontext_t {
    var out_gc: c.xcb_gcontext_t = gc;
    if (out_gc == 0) {
        out_gc = c.xcb_generate_id(conn);
    }

    // Create the GC, check for errors
    if (comptime util.isDebug) {
        const create_cookie = c.xcb_create_gc_checked(conn, out_gc, win, 0, null);
        XlibTerminal.testCookie(
            create_cookie,
            conn,
            "cannot create gc in create_gc",
        );

        const value_mask: u32 = c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
        const values: [2]u32 = .{
            fg,
            bg,
        };
        _ = c.xcb_change_gc(conn, out_gc, value_mask, &values);

        return out_gc;
    } else {
        _ = c.xcb_create_gc(
            conn,
            out_gc,
            win,
            0,
            null,
        );

        const value_mask: u32 = c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND;
        const values: [2]u32 = .{
            fg,
            bg,
        };
        _ = c.xcb_change_gc(conn, out_gc, value_mask, &values);

        return out_gc;
    }
}

pub inline fn set_fg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
    _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &[_]u32{p});
    return p;
}
pub inline fn set_bg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
    _ = c.xcb_change_gc(conn, gc, c.XCB_GC_BACKGROUND, &[_]u32{p});
    return p;
}

pub inline fn get_rgb_pixel(
    conn: *c.xcb_connection_t,
    cmap: c.xcb_colormap_t,
    r: u16,
    g: u16,
    b: u16,
) u32 {
    const color: c.xcb_alloc_color_cookie_t = c.xcb_alloc_color(
        conn,
        cmap,
        @intCast(r),
        @intCast(g),
        @intCast(b),
    );
    const rpl_color: *c.xcb_alloc_color_reply_t = c.xcb_alloc_color_reply(conn, color, null);
    defer std.c.free(rpl_color);
    const p = rpl_color.pixel;
    return @intCast(p);
}

pub fn color_alloc_value(
    conn: *c.xcb_connection_t,
    visual: *c.xcb_visualtype_t,
    cmap: c.xcb_colormap_t,
    color: *const RenderColor,
    result: *Color,
) bool {
    if (visual._class == c.XCB_VISUAL_CLASS_TRUE_COLOR) {
        const red_shift = @as(u5, @intCast(@ctz(visual.red_mask)));
        const red_len = @as(u5, @intCast(@popCount(visual.red_mask)));
        const green_shift = @as(u5, @intCast(@ctz(visual.green_mask)));
        const green_len = @as(u5, @intCast(@popCount(visual.green_mask)));
        const blue_shift = @as(u5, @intCast(@ctz(visual.blue_mask)));
        const blue_len = @as(u5, @intCast(@popCount(visual.blue_mask)));

        const red_part = (@as(u32, color.red) >> @as(u5, 16 - red_len)) << red_shift;
        const green_part = (@as(u32, color.green) >> @as(u5, 16 - green_len)) << green_shift;
        const blue_part = (@as(u32, color.blue) >> @as(u5, 16 - blue_len)) << blue_shift;

        result.pixel = red_part | green_part | blue_part;

        if (visual.bits_per_rgb_value == 32) {
            result.pixel |= (@as(u32, color.alpha >> 8) << 24);
        }
    } else {
        const cookie = c.xcb_alloc_color(
            conn,
            cmap,
            @truncate(color.red),
            @truncate(color.green),
            @truncate(color.blue),
        );

        if (c.xcb_alloc_color_reply(conn, cookie, null)) |reply| {
            defer std.c.free(reply);
            result.pixel = reply.*.pixel;
        } else {
            return false;
        }
    }

    result.color = color.*;
    return true;
}

pub inline fn color_alloc_name(
    conn: *c.xcb_connection_t,
    // visual: *c.xcb_visualtype_t,
    cmap: c.xcb_colormap_t,
    name: [*:0]const u8,
    result: *Color,
) bool {
    const cookie = c.xcb_alloc_named_color(
        conn,
        cmap,
        @intCast(std.mem.len(name)),
        name,
    );

    if (c.xcb_alloc_named_color_reply(conn, cookie, null)) |reply| {
        defer std.c.free(reply);
        result.pixel = reply.*.pixel;
        result.color.red = @as(u16, reply.*.exact_red);
        result.color.green = @as(u16, reply.*.exact_green);
        result.color.blue = @as(u16, reply.*.exact_blue);
        result.color.alpha = 0xffff;
        return true;
    }
    return false;
}

pub inline fn get_pixel(conn: *c.xcb_connection_t, cmap: c.xcb_colormap_t, color: []const u8) u32 {
    const color_cookie = c.xcb_alloc_named_color(conn, cmap, @intCast(color.len), color.ptr);

    const reply = c.xcb_alloc_named_color_reply(conn, color_cookie, null);

    defer std.c.free(reply);

    return @intCast(reply.pixel);
}

// pub const struct_xcb_visualtype_t = extern struct {
//     visual_id: xcb_visualid_t = @import("std").mem.zeroes(xcb_visualid_t),
//     _class: u8 = @import("std").mem.zeroes(u8),
//     bits_per_rgb_value: u8 = @import("std").mem.zeroes(u8),
//     colormap_entries: u16 = @import("std").mem.zeroes(u16),
//     red_mask: u32 = @import("std").mem.zeroes(u32),
//     green_mask: u32 = @import("std").mem.zeroes(u32),
//     blue_mask: u32 = @import("std").mem.zeroes(u32),
//     pad0: [4]u8 = @import("std").mem.zeroes([4]u8),
// };

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

const Atoms = packed struct {
    xembed: c.xcb_atom_t,
    wmdeletewin: c.xcb_atom_t,
    netwmname: c.xcb_atom_t,
    netwmiconname: c.xcb_atom_t,
    netwmpid: c.xcb_atom_t,
};

pub const XlibTerminal = struct {
    connection: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    window: c.xcb_window_t,
    pixmap: c.xcb_pixmap_t,
    allocator: Allocator,
    pty: justty.Pty,
    pid: posix.pid_t,
    visual: VisualData,
    cursor: c.xcb_cursor_t,
    cursor_font: c.xcb_font_t,
    atoms: Atoms,
    ft: font.FreeType,
    fc: font.Fontconfig,
    // colormap: c.xcb_colormap_t,

    dc: DC,
    // gc_values: c.xcb_change_gc_value_list_t,
    output: [1024]u8 = undefined, // Buffer to store pty output
    win: TermWindow,
    // buf: c.xcb_drawable_t,
    //============================attrs x ===============================//
    // attrs: c.XSetWindowAttributes,
    //===================================================================//
    output_len: usize = 0, // Length of stored output

    const Self = @This();

    inline fn testCookie(cookie: c.xcb_void_cookie_t, conn: *c.xcb_connection_t, err_msg: []const u8) void {
        const e = c.xcb_request_check(conn, cookie);
        if (e != null) {
            std.log.err("ERROR: {s} : {}", .{ err_msg, e.*.error_code });
            c.xcb_disconnect(conn);
            std.process.exit(1);
        }
    }

    pub fn init(allocator: Allocator) !Self {
        // const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        const connection = c.xcb_connect(null, null) orelse return error.CannotOpenDisplay;
        // errdefer _ = c.XCloseDisplay(display);
        errdefer _ = c.xcb_disconnect(connection);
        if (c.xcb_connection_has_error(connection) != 0) {
            return error.CannotOpenDisplay;
        }

        //getting screen

        const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;

        // const screen = c.XDefaultScreen(display);
        const root = screen.*.root;
        const visual = screen.*.root_visual;

        //====================================font ===============================//
        if ((c.FcInit() == 0)) {
            return error.Fcinit_errror_created;
        }
        //load fonts TODO:make function wrapper for all moves
        const ft = try font.FreeType.init();
        errdefer ft.deinit();

        var fc = font.Fontconfig.init();
        errdefer fc.deinit();

        const font_str = c.font;
        const pat = font.Pattern.parse(font_str);
        errdefer pat.destroy();

        var iter = try fc.discoverFromPattern(pat);
        errdefer iter.deinit();
        const font_pattern = (try iter.next()) orelse return error.CannotFindFont;
        errdefer font_pattern.destroy();
        iter.deinit();

        const file_val = font_pattern.get(.file, 0) orelse return error.CannotGetfile_val;
        const file = switch (file_val) {
            .string => |s| s,
            else => return error.CannotGetFontFile,
        };

        var ft_face: c.FT_Face = undefined;
        try font.intToError(c.FT_New_Face(ft.handle, file.ptr, 0, &ft_face));
        errdefer _ = c.FT_Done_Face(ft_face);
        const face = font.Face{ .handle = ft_face };

        // set Unicode charmap
        try face.selectCharmap(.unicode);

        var pixel_size: f32 = 12.0; // default
        if (font_pattern.get(.pixel_size, 0)) |val| {
            pixel_size = switch (val) {
                .double => |d| @floatCast(d),
                .integer => |i| @floatFromInt(i),
                else => pixel_size,
            };
        }

        // get pixelsize if get
        // char size

        try face.setCharSize(0, @as(i32, @intFromFloat(pixel_size * 64)), 96, 96);
        const metrics = ft_face.*.size.*.metrics;
        const cw = @as(u32, @intCast((metrics.max_advance + 63) >> 6));
        const ch = @as(u32, @intCast((metrics.height + 63) >> 6));
        const ascent = @as(usize, @intCast((metrics.ascender + 63) >> 6));
        // errdefer _ = c.XftFontClose(display, _font_);
        //load fonts function

        // colormap
        //
        //
        // const cmap = c.XDefaultColormap(display, screen);
        // const cmap = screen.*.default_colormap;
        //load colors
        //adjust fixed window geometry //
        const border_px = @as(u32, @intCast(c.borderpx)); // u32
        const cols_u32 = @as(u32, @intCast(c.cols)); // u8
        const rows_u32 = @as(u32, @intCast(c.rows)); // u8
        var win: TermWindow = .{
            .mode = .MODE_NUMLOCK,
            .tw = cols_u32,
            .th = rows_u32,
            .cw = cw,
            .ch = ch,
            .w = 2 * border_px + cols_u32 * cw,
            .h = 2 * border_px + rows_u32 * ch,
            .cursor = c.mouseshape,
        };

        //============drawing_context======================//
        var dc: DC = undefined;
        errdefer _ = c.xcb_free_gc(connection, dc.gc);
        // dc.col = try allocator.alloc(c.XftColor, dc.len); //alloc

        dc.font = .{
            .height = @intCast(ch),
            .width = @intCast(cw),
            .ascent = @intCast(ascent),
            .face = face,
        };

        const visual_data = try VisualData.init(screen);
        if (comptime util.isDebug) {
            std.log.info("Visual depth: {}, visual_id: {}", .{ visual_data.visual_depth, visual_data.visual.visual_id });
        }

        for (&dc.col, 0..) |*color, i| {
            if (!xloadcolor(connection, screen, visual_data.visual, i, null, color)) {
                if (i < c.colorname.len and c.colorname[i] != null) {
                    std.log.err("cannot allocate color name={s}", .{c.colorname[i].?});
                    return error.CannotAllocateColor;
                } else {
                    std.log.err("cannot allocate color {}", .{i});
                    return error.CannotAllocateColor;
                }
            }
            if (comptime util.isDebug) {
                std.log.debug("Background color (index {}): pixel={x}, R={}, G={}, B={}", .{
                    i,
                    color.pixel,
                    color.color.red >> 8,
                    color.color.green >> 8,
                    color.color.blue >> 8,
                });
            }
        }

        // //attrs
        // var attrs: c.XSetWindowAttributes = undefined;
        // attrs.background_pixel = dc.col[c.defaultbg].pixel;
        // attrs.border_pixel = dc.col[c.defaultbg].pixel;
        // attrs.bit_gravity = c.NorthWestGravity;

        // attrs.event_mask = c.FocusChangeMask | c.KeyPressMask | c.KeyReleaseMask | c.ExposureMask | c.VisibilityChangeMask | c.StructureNotifyMask | c.ButtonMotionMask | c.ButtonPressMask | c.ButtonReleaseMask;
        // attrs.colormap = cmap;
        const window = c.xcb_generate_id(connection);
        const mask = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_COLORMAP;
        const values = [_]u32{
            screen.*.black_pixel,
            c.XCB_EVENT_MASK_EXPOSURE |
                c.XCB_EVENT_MASK_KEY_PRESS |
                c.XCB_EVENT_MASK_KEY_RELEASE |
                c.XCB_EVENT_MASK_BUTTON_PRESS |
                c.XCB_EVENT_MASK_BUTTON_RELEASE |
                c.XCB_EVENT_MASK_BUTTON_MOTION |
                c.XCB_EVENT_MASK_FOCUS_CHANGE |
                c.XCB_EVENT_MASK_VISIBILITY_CHANGE |
                c.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
            screen.*.default_colormap,
        };

        _ = c.xcb_create_window(
            connection,
            screen.*.root_depth,
            window,
            root,
            0,
            0,
            @as(u16, @intCast(win.w)),
            @as(u16, @intCast(win.h)),

            0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            visual,
            mask,
            &values,
        );

        if (window == 0) return error.CannotCreateWindow;
        errdefer _ = c.xcb_destroy_window(connection, window);
        //============ pixmap =============================//
        const pixmap = c.xcb_generate_id(connection);
        _ = c.xcb_create_pixmap(connection, screen.*.root_depth, pixmap, window, @as(u16, @intCast(win.w)), @as(u16, @intCast(win.h)));
        errdefer _ = c.xcb_free_pixmap(connection, pixmap);

        //==================gc values=====================//
        dc.gc = c.xcb_generate_id(connection);
        errdefer _ = c.xcb_free_gc(connection, dc.gc);

        dc.gc = create_gc(
            connection,
            dc.gc,
            window,
            dc.col[c.defaultfg].pixel,
            dc.col[c.defaultbg].pixel,
        );
        _ = set_fg(connection, dc.gc, dc.col[c.defaultfg].pixel);

        _ = c.xcb_poly_fill_rectangle(
            connection,
            pixmap,
            dc.gc,
            1,
            &[_]c.xcb_rectangle_t{
                .{
                    .x = 0,
                    .y = 0,
                    .width = @as(u16, @intCast(win.w)),
                    .height = @as(u16, @intCast(win.h)),
                },
            },
        );

        // ================drawable =======================//
        // const draw = c.XftDrawCreate(display, buf, visual, cmap);
        //
        // const draw = c.XftDrawCreate(display, buf, visual, cmap) orelse return error.CannotCreateDraw;
        //================= inputs TODO:FINISH INPUT METHODS //
        // _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

        const initial_size: justty.winsize = .{ .ws_row = c.rows, .ws_col = c.cols, .ws_xpixel = 0, .ws_ypixel = 0 };

        //========================cursor =================//
        const xcb_font: c.xcb_font_t = c.xcb_generate_id(connection);
        if (comptime util.isDebug) {
            const fontCookie: c.xcb_void_cookie_t = c.xcb_open_font_checked(
                connection,
                xcb_font,
                @intCast(c.strlen("cursor")),
                "cursor",
            );
            testCookie(fontCookie, connection, "can't open cursor font");
        }
        // const cursor_context = c.xcb_cursor_context_new(connection, screen) orelse return error.CannotCreateCursorContext;
        const cursor: c.xcb_cursor_t = c.xcb_generate_id(connection);
        const cursor_id = @as(u16, @intCast(c.mouseshape));
        _ = c.xcb_create_glyph_cursor(
            connection,
            cursor,
            xcb_font,
            xcb_font,
            cursor_id,
            cursor_id + 1,
            @as(u16, dc.col[c.mousefg].color.red),
            @as(u16, dc.col[c.mousefg].color.green),
            @as(u16, dc.col[c.mousefg].color.blue),
            @as(u16, dc.col[c.mousebg].color.red),
            @as(u16, dc.col[c.mousebg].color.green),
            @as(u16, dc.col[c.mousebg].color.blue),
        );
        errdefer _ = c.xcb_free_cursor(connection, cursor);
        // const cursor = c.XCreateFontCursor(display, c.mouseshape);
        // _ = c.XDefineCursor(display, window, cursor);
        // var xmousefg: c.XColor = undefined;
        // var xmousebg: c.XColor = undefined;

        win.cursor = @as(u32, @intCast(cursor));

        // if (c.XParseColor(display, cmap, c.colorname[c.mousefg], @intFromPtr(&xmousefg)) == 0) {
        //     xmousefg.red = 0xffff; // Xcolor
        //     xmousefg.green = 0xffff;
        //     xmousefg.blue = 0xffff;
        // }

        // if (c.XParseColor(display, cmap, c.colorname[c.mousebg], @intFromPtr(&xmousebg)) == 0) {
        //     xmousebg.red = 0x0000;
        //     xmousebg.green = 0x0000;
        //     xmousebg.blue = 0x0000;
        // }
        // _ = c.XRecolorCursor(display, cursor, @intFromPtr(&xmousefg), @intFromPtr(&xmousebg));
        const atom_names = [_][]const u8{ "_XEMBED", "WM_DELETE_WINDOW", "_NET_WM_NAME", "_NET_WM_ICON_NAME", "_NET_WM_PID" };
        var atoms: Atoms = undefined;
        for (atom_names, 0..) |name, i| {
            const cookie = c.xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr);
            const reply = c.xcb_intern_atom_reply(connection, cookie, null) orelse return error.CannotInternAtom;
            defer std.c.free(reply);
            switch (i) {
                0 => atoms.xembed = reply.*.atom,
                1 => atoms.wmdeletewin = reply.*.atom,
                2 => atoms.netwmname = reply.*.atom,
                3 => atoms.netwmiconname = reply.*.atom,
                4 => atoms.netwmpid = reply.*.atom,
                else => unreachable,
            }
        }

        // win.mode = MODE_NUMLOCK;

        //==================atom ======================//
        //============================================//

        var pty = try justty.Pty.open(initial_size);

        errdefer pty.deinit();
        const pid = try posix.fork();
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            window,
            atoms.wmdeletewin,
            c.XCB_ATOM_ATOM,
            32,
            1,
            &atoms.wmdeletewin,
        );
        try pty.exec(pid);
        _ = c.xcb_map_window(connection, window);
        _ = c.xcb_flush(connection);

        return .{
            .visual = visual_data,
            // .attrs = attrs,
            // .gc_values = gcvalues,
            .connection = connection,
            .screen = screen,
            .window = window,
            .pixmap = pixmap,
            .cursor = cursor,
            .cursor_font = xcb_font,
            .ft = ft,
            .fc = fc,
            .allocator = allocator,
            .pty = pty,
            .pid = pid,
            .atoms = atoms,
            .dc = dc,
            .win = win,
        };
    }

    inline fn sixd_to_16bit(x: u3) u16 {
        return @as(u16, @intCast(if (x == 0) 0 else 0x3737 + 0x2828 * @as(u16, @intCast(x))));
    }

    inline fn xloadcolor(
        conn: *c.xcb_connection_t,
        screen: *c.xcb_screen_t,
        visual: *c.xcb_visualtype_t,
        i: usize,
        color_name: ?[*:0]const u8,
        color: *Color,
    ) bool {
        color.color.alpha = 0xffff;

        const name = color_name orelse blk: {
            if (16 <= i and i <= 255) {
                var xcolor: RenderColor = .{ .alpha = 0xffff, .red = 0, .green = 0, .blue = 0 };

                if (i < 6 * 6 * 6 + 16) {
                    const step = i - 16;
                    xcolor.red = sixd_to_16bit(@intCast((step / 36) % 6));
                    xcolor.green = sixd_to_16bit(@intCast((step / 6) % 6));
                    xcolor.blue = sixd_to_16bit(@intCast(step % 6));
                } else {
                    const val = (@as(
                        u16,
                        (0x0808 + 0x0a0a * @as(
                            u16,
                            @intCast(i - (6 * 6 * 6 + 16)),
                        )) >> 8,
                    ));
                    xcolor.red = val;
                    xcolor.green = val;
                    xcolor.blue = val;
                }
                return color_alloc_value(
                    conn,
                    visual,
                    screen.*.default_colormap,
                    &xcolor,
                    color,
                );
            }
            break :blk c.colorname[i];
        };

        if (name == null) return false;

        if (name[0] == '#') {
            const hex_str = name[1..7];
            var rgb: u24 = 0;
            if (std.fmt.hexToBytes(std.mem.asBytes(&rgb), hex_str)) |_| {
                const xcolor = RenderColor{
                    .red = @as(u16, @truncate(rgb >> 16)) << 8,
                    .green = @as(u16, @truncate(rgb >> 8)) << 8,
                    .blue = @as(u16, @truncate(rgb)) << 8,
                    .alpha = 0xffff,
                };
                return color_alloc_value(
                    conn,
                    visual,
                    screen.*.default_colormap,
                    &xcolor,
                    color,
                );
            } else |_| {
                return false;
            }
        }

        return color_alloc_name(
            conn,
            screen.*.default_colormap,
            name,
            color,
        );
    }
    // Error set for xgetcolor
    const XGetColorError = error{
        InvalidColorIndex,
    };

    /// Retrieves the RGB components of the color at index x from dc.col.
    /// Parameters:
    /// - x: The color index to retrieve.
    /// - r: Pointer to store the red component (0-255).
    /// - g: Pointer to store the green component (0-255).
    /// - b: Pointer to store the blue component (0-255).
    /// Returns: void on success, or an error if the index is out of bounds.
    pub fn xgetcolor(dc: *DC, x: i32, r: *u8, g: *u8, b: *u8) XGetColorError!void {
        // Check if x is within bounds (BETWEEN(x, 0, dc.collen - 1))
        if (x < 0 or x >= @as(i32, @intCast(dc.collen))) {
            return error.InvalidColorIndex;
        }

        // Extract RGB components, shifting from 16-bit (0xFFFF) to 8-bit (0xFF)
        const color = dc.col[@intCast(x)].pixel;
        r.* = @intCast(color.red >> 8);
        g.* = @intCast(color.green >> 8);
        b.* = @intCast(color.blue >> 8);
    }

    pub fn run(self: *Self) !void {
        const xfd = c.xcb_get_file_descriptor(self.connection);
        var fds: [2]std.posix.pollfd = .{
            .{ .fd = xfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.pty.master, .events = std.posix.POLL.IN, .revents = 0 },
        };
        var buffer: [8024]u8 = undefined;

        while (true) {
            _ = std.posix.poll(&fds, -1) catch |err| {
                std.log.err("poll error: {}", .{err});
                return err;
            };

            if (fds[0].revents & std.posix.POLL.IN != 0) {
                while (true) {
                    const event = c.xcb_poll_for_event(self.connection) orelse break;
                    defer std.c.free(event);
                    try self.handleEvent(event);
                }
            }

            if (fds[1].revents & std.posix.POLL.IN != 0) {
                const n = posix.read(self.pty.master, &buffer) catch |err| {
                    std.log.err("read error from pty: {}", .{err});
                    continue;
                };
                if (n > 0) {
                    const end = @min(self.output_len + n, self.output.len);
                    util.copy(u8, self.output[self.output_len..end], buffer[0..n]);
                    self.output_len = end;
                    try self.redraw();
                } else if (n == 0) {
                    break;
                }
            }
        }
    }

    fn handleEvent(self: *Self, event: *c.xcb_generic_event_t) !void {
        const EVENT_MASK = ~@as(u8, 0x80);
        const event_type = event.response_type & EVENT_MASK;
        switch (event_type) {
            c.XCB_EXPOSE => try self.redraw(),
            c.XCB_KEY_PRESS => {
                const key_event = @as(*c.xcb_key_press_event_t, @ptrCast(event));
                const keysym = key_event.detail;
                if (keysym >= 32 and keysym <= 126) {
                    const char = @as(u8, @intCast(keysym));
                    _ = posix.write(self.pty.master, &[_]u8{char}) catch {};
                }
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const config_event = @as(*c.xcb_configure_notify_event_t, @ptrCast(event));
                const new_size = justty.winsize{
                    .ws_row = @intCast(@divTrunc(config_event.height, @as(u16, @intCast(self.dc.font.height)))),
                    .ws_col = @intCast(@divTrunc(config_event.width, @as(u16, @intCast(self.dc.font.width)))),
                    .ws_xpixel = 0,
                    .ws_ypixel = 0,
                };
                self.pty.resize(new_size) catch {};
            },
            else => {},
        }
    }

    fn convert_to_24bit_buffer(allocator: Allocator, buffer: []u32, width: u32, height: u32, bgr: bool) ![]u8 {
        const stride = (width * 3 + 3) & ~@as(u32, 3);
        const out = try allocator.alloc(u8, stride * height);
        @memset(out, 0);
        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = buffer[y * width + x];
                const idx = y * stride + x * 3;
                if (bgr) {
                    out[idx + 0] = @truncate(pixel & 0xFF); // B
                    out[idx + 1] = @truncate((pixel >> 8) & 0xFF); // G
                    out[idx + 2] = @truncate((pixel >> 16) & 0xFF); // R
                } else {
                    out[idx + 0] = @intCast((pixel >> 16) & 0xFF); // R
                    out[idx + 1] = @intCast((pixel >> 8) & 0xFF); // G
                    out[idx + 2] = @intCast(pixel & 0xFF); // B
                }
            }
        }
        if (comptime util.isDebug) {
            std.log.info("Converted buffer to 24-bit, size: {}, stride: {}", .{ out.len, stride });
        }
        return out;
    }

    fn redraw(self: *Self) !void {
        const bg = self.dc.col[c.defaultbg];
        const bg_pixel = bg.pixel;

        const fg = self.dc.col[c.defaultfg];
        const fg_pixel = fg.pixel;

        if (comptime util.isDebug) {
            std.log.info("Screen root_depth: {}, visual_depth: {}", .{ self.screen.root_depth, self.visual.visual_depth });
            std.log.debug("Background pixel: {x}, Foreground pixel: {x}", .{ bg_pixel, fg_pixel });
        }
        // _ = set_bg(self.connection, self.dc.gc, bg_pixel);

        // _ = c.xcb_change_gc(self.connection, self.dc.gc, c.XCB_GC_FOREGROUND, &[_]u32{bg_pixel});

        // _ = c.xcb_poly_fill_rectangle(
        //     self.connection,
        //     self.pixmap,
        //     self.dc.gc,
        //     1,
        //     &[_]c.xcb_rectangle_t{
        //         .{
        //             .x = 0,
        //             .y = 0,
        //             .width = @as(u16, @intCast(self.win.w)),
        //             .height = @as(u16, @intCast(self.win.h)),
        //         },
        //     },
        // );

        const width = self.win.w;
        const height = self.win.h;
        const buffer = self.allocator.alloc(u32, width * height) catch return;
        defer self.allocator.free(buffer);
        @memset(buffer, bg_pixel);
        // _ = set_fg(self.connection, self.dc.gc, fg_pixel);

        // const data = if (self.screen.root_depth == 24) blk: {
        //     const data_24 = try convert_to_24bit_buffer(self.allocator, buffer, width, height, false);
        //     defer self.allocator.free(data_24);
        //     break :blk data_24;
        // } else @as([*]const u8, @ptrCast(buffer.ptr))[0 .. width * height * 4];

        var y: i32 = @intCast(self.dc.font.ascent);
        var start: usize = 0;
        while (start < self.output_len) {
            var end = start;
            while (end < self.output_len and self.output[end] != '\n') end += 1;

            var x: i32 = 10;
            for (self.output[start..end]) |char| {
                const glyph_index = self.dc.font.face.getCharIndex(char) orelse continue;
                self.dc.font.face.loadGlyph(glyph_index, .{ .render = true }) catch continue;
                self.dc.font.face.renderGlyph(.normal) catch continue;

                const bitmap = self.dc.font.face.handle.*.glyph.*.bitmap;
                const bitmap_left = self.dc.font.face.handle.*.glyph.*.bitmap_left;
                const bitmap_top = self.dc.font.face.handle.*.glyph.*.bitmap_top;

                if (bitmap.buffer != null and bitmap.width > 0 and bitmap.rows > 0) {
                    var py: u32 = 0;
                    while (py < bitmap.rows) : (py += 1) {
                        var px: u32 = 0;
                        while (px < bitmap.width) : (px += 1) {
                            const alpha = bitmap.buffer[py * @as(u32, @intCast(bitmap.pitch)) + px];
                            if (alpha > 0) {
                                const buf_x = @as(u32, @intCast(x + @as(i32, @intCast(px)) + bitmap_left));
                                const buf_y = @as(u32, @intCast(y - bitmap_top + @as(i32, @intCast(py))));
                                if (buf_x < width and buf_y < height) {
                                    buffer[buf_y * width + buf_x] = fg_pixel;
                                }
                            }
                        }
                    }
                }

                x += @intCast(self.dc.font.face.handle.*.glyph.*.advance.x >> 6);
            }

            y += @intCast(self.dc.font.height);
            start = end + 1;
            if (y > @as(i32, @intCast(self.win.h))) break;
        }

        if (comptime util.isDebug) {
            const image_cookie = c.xcb_put_image_checked(
                self.connection, // 1: connection
                c.XCB_IMAGE_FORMAT_Z_PIXMAP, // 2: format
                self.pixmap, // 3: drawable
                self.dc.gc, // 4: gc
                @intCast(width), // 5: width
                @intCast(height), // 6: height
                0, // 7: dst_x
                0, // 8: dst_y
                0, // 9: left_pad
                self.screen.root_depth, // 10: depth
                @intCast(width * height * 4), // 11: data_len

                // data.ptr, // 12: data
                @ptrCast(@as([*]const u8, @ptrCast(buffer.ptr))[0 .. width * height * 4]),
            );
            testCookie(image_cookie, self.connection, "can't put image");
            _ = c.xcb_flush(self.connection);
        } else {
            _ = c.xcb_put_image(
                self.connection, // 1: connection
                c.XCB_IMAGE_FORMAT_Z_PIXMAP, // 2: format
                self.pixmap, // 3: drawable
                self.dc.gc, // 4: gc
                @intCast(width), // 5: width
                @intCast(height), // 6: height
                0, // 7: dst_x
                0, // 8: dst_y
                0, // 9: left_pad
                self.screen.root_depth, // 10: depth
                @intCast(width * height * 4), // 11: data_len
                @ptrCast(@as([*]const u8, @ptrCast(buffer.ptr))[0 .. width * height * 4]),
            );

            _ = c.xcb_copy_area(
                self.connection,
                self.pixmap,
                self.window,
                self.dc.gc,
                0,
                0,
                0,
                0,
                @as(u16, @intCast(self.win.w)),
                @as(u16, @intCast(self.win.h)),
            );
        }

        _ = c.xcb_flush(self.connection);
    }

    pub fn deinit(self: *Self) void {
        self.pty.deinit();
        // self.allocator.free(self.dc.col);
        self.dc.font.face.deinit();
        self.fc.deinit();
        self.ft.deinit();
        // for (&self.dc.col) |*color| {
        //     c.XftColorFree(self.display, self.vis, self.colormap, color);
        // }
        // _ = c.XftDrawDestroy(self.draw);
        // _ = c.XftFontClose(self.display, self.font);
        // _ = c.XDestroyWindow(self.display, self.window);
        // _ = c.XCloseDisplay(self.display);

        // _ = c.XFreePixmap(self.display, self.buf);
        // _ = c.XFreeGC(self.display, self.dc.gc);

        _ = c.xcb_free_gc(self.connection, self.dc.gc);
        _ = c.xcb_free_pixmap(self.connection, self.pixmap);
        _ = c.xcb_destroy_window(self.connection, self.window);
        _ = c.xcb_disconnect(self.connection);
    }
};
