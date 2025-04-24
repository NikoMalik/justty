const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const justty = @import("justty.zig");
const font = @import("font.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
//*root window - its This is the root window of the X11 display, covering the entire screen.
// It is controlled by the window manager and serves as a parent for all other windows in the application.
//It is not directly involved in rendering, but provides a coordinate system and context for other windows.

//*main_window The main terminal window containing design elements (title bar, frames) that are usually added by the window manager.
// It is the parent of vt_window.
//Responsible for interaction with the window manager (e.g. resize, move, focus).
// (text, cursor) are displayed and user inputs (keys, mouse) are processed

//
//root_window
//└── main_window

const Key = packed struct(u64) {
    key_sym: c.xcb_keysym_t,
    mode: u32,
};

pub const masks = union(enum(u32)) {

    // mainWinMode
    pub const WINDOW_WM: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK;
    pub const CHILD_EVENT_MASK: u32 = c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_BUTTON_MOTION;

    pub const WINDOW_CURSOR: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_CURSOR;
};

const elements = enum(u8) {
    COPY_FROM_PARENT = c.XCB_COPY_FROM_PARENT,
};

const GLyphMode = std.bit_set.IntegerBitSet(13);

const WinMode = std.bit_set.IntegerBitSet(19);

const TermMode = std.bit_set.IntegerBitSet(7);

const Glyph_flags = enum(u4) {
    ATTR_NULL = 0,
    ATTR_BOLD = 1,
    ATTR_FAINT = 2,
    ATTR_ITALIC = 3,
    ATTR_UNDERLINE = 4,
    ATTR_BLINK = 5,
    ATTR_REVERSE = 6,
    ATTR_INVISIBLE = 7,
    ATTR_STRUCK = 8,
    ATTR_WRAP = 8,
    ATTR_WIDE = 10,
    ATTR_WDUMMY = 11,
    ATTR_BOLD_FAINT = 12,
};

const TermModeFlags = enum(u3) {
    MODE_WRAP = 0,
    MODE_INSERT = 1,
    MODE_ALTSCREEN = 2,
    MODE_CRLF = 3,
    MODE_ECHO = 4,
    MODE_PRINT = 5,
    MODE_UTF8 = 6,
};

const WinModeFlags = enum(u5) {
    MODE_VISIBLE = 0,
    MODE_FOCUSED = 1,
    MODE_APPKEYPAD = 2,
    MODE_MOUSEBTN = 3,
    MODE_MOUSEMOTION = 4,
    MODE_REVERSE = 5,
    MODE_KBDLOCK = 6,
    MODE_HIDE = 7,
    MODE_APPCURSOR = 8,
    MODE_MOUSESGR = 9,
    MODE_8BIT = 10,
    MODE_BLINK = 11,
    MODE_FBLINK = 12,
    MODE_FOCUS = 13,
    MODE_MOUSEX10 = 14,
    MODE_MOUSEMANY = 15,
    MODE_BRCKTPASTE = 16,
    MODE_NUMLOCK = 17,
    MODE_MOUSE = 18,
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

const S = struct {
    var main_window_id: c.xcb_window_t = 0;
    var main_initialized: bool = false; // make in flags if has more  8
    var root_window: c.xcb_window_t = 0;
    var root_initialized: bool = false;
};

// Purely graphic info //
const TermWindow = struct {
    mode: WinMode,
    ///*tty width and height */
    tty_grid: Grid, // tw и th → tty_size.w and tty_size.h
    //*window width and height */
    win_size: Size, // w и h → win_size.width and win_size.height
    // /*char height and width */
    char_size: Size, // cw и ch → char_size.w and char_size.h
    cursor: u16 = c.CURSORSHAPE,
};

const Font = struct {
    face: font.Face,
    size: Size,
    ascent: u32,
};
// Drawing Context
const DC = struct {
    col: [260]Color, // len: usize,
    font: Font,
    gc: c.xcb_gcontext_t,
};

/// size pixels (windows, symbols, fonts).
pub const Size = packed struct(u32) {
    width: u16,
    height: u16,
};

/// count
pub const Grid = packed struct(u32) {
    cols: u16,
    rows: u16,
};

pub const Position = packed struct(u32) {
    x: u16,
    y: u16,
};

pub const Bounds = packed struct(u32) {
    top: u16,
    bottom: u16,
};

/// limitation or indexes (for example, min value or index of line ).
pub const Constraints = packed struct(u32) {
    min: u16, // min value (for example lines)
    index: u16, // index (for example index of line)
};

//Represents a single “cell” of the screen with the symbol and its attributes:
// grid based interfaces
pub const Glyph = struct {
    mode: GLyphMode, // flags BOLD,ITALIC and more
    u: u32 = 0, //unicode  char
    fg_index: u9 = @as(u9, @intCast(c.defaultfg)), //foreground
    bg_index: u9 = @as(u9, @intCast(c.defaultbg)), //background
};

const DirtySet = std.bit_set.ArrayBitSet(u32, c.MAX_ROWS);

const Term = struct {
    mode: TermMode, // Terminal modes
    /// Allocator
    allocator: Allocator,
    //(e.g., line auto-transfer, alternate screen, UTF-8).
    dirty: DirtySet, //Bitmask to keep track of “dirty” rows that need to be redrawn.
    line: [c.MAX_ROWS][]Glyph, // Array of strings with fixed size MAX_ROWS
    alt: [c.MAX_ROWS][]Glyph, // alt array(for example vim,htop) of strings with fixes size MAX_ROWS

    //For an 80x24 character terminal with a Glyph size of 16 bytes, one screen takes ~30 KB.
    //Two screens - ~60 KB. can we use union for 60kb? mb not
    size_grid: Grid, // Grid size (cols, rows)
    cursor: TCursor, //cursor
    tabs: [c.MAX_COLS]u8,
    ocx: u16 = 0, // Previous cursor position X
    ocy: u16 = 0, // Previous cursor position Y
    top: u16 = 0, // Upper scroll limit
    bot: u16 = 0, // Lower scroll limit
    esc: u16 = 0, // Status of ESC sequences
    charset: u16 = 0, // Current encoding
    icharset: u16 = 0, // Encoding index
    trantbl: [4]u8, // /* charset table translation */
    cursor_visible: bool, // Cursor visibility

    fn handle_esc_sequence(self: *Term, sequence: []const u8) void {
        if (std.mem.eql(u8, sequence, "[?1049h")) {
            self.mode.set(@intFromEnum(TermModeFlags.MODE_ALTSCREEN));
        } else if (std.mem.eql(u8, sequence, "[?1049l")) {
            self.mode.unset(@intFromEnum(TermModeFlags.MODE_ALTSCREEN));
        }
    }

    fn tlinelen(self: *Term, y: u32) u32 {
        var i = self.size_grid.cols;

        if (self.line[y][i - 1].mode.isSet(Glyph_flags.ATTR_WRAP))
            return i;
        while (i > 0 and self.line[y][i - 1].u == ' ')
            i -= 1;

        return i;
    }

    fn parse_esc(self: *Term, data: []const u8) void {
        for (data) |byte| {
            switch (self.esc) {
                0 => {
                    if (byte == 0x1B) self.esc = 1;
                },
                1 => {
                    if (byte == '[') self.esc = 2 else self.esc = 0;
                },
                2 => {
                    switch (byte) {
                        'J' => {
                            if (self.mode.isSet(@intFromEnum(TermModeFlags.MODE_ALTSCREEN))) {
                                @memset(self.alt, Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg });
                            } else {
                                @memset(self.line, Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg });
                            }
                            self.dirty.setRangeValue(0, self.size_grid.rows, true);
                            self.esc = 0;
                        },
                        'H' => {
                            self.cursor.pos = Position{ .x = 0, .y = 0 };
                            self.esc = 0;
                        },
                        else => self.esc = 0,
                    }
                },
                else => self.esc = 0,
            }
        }
    }
};

const Selection = struct {
    xtarget: c.xcb_atom_t,
    clipcopy: union {
        primary: ?[]u8,
        clipboard: ?[]u8,
    },
    tclick1: c.timespec,
    tclick2: c.timespec,
};
//current cursor
const TCursor = struct {
    attr: Glyph, //current char attrs
    pos: Position, // pos.x and pos.y for cursor position
    state: u8 = 0,
};

pub const Arg = union {
    i: i32,
    ui: u32,
    f: f64,
    v: ?*anyopaque,
    none: void,
    //current char attrs
    pub const None = &Arg{ .none = {} };
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

pub inline fn TIMEDIFF(t1: c.struct_timespec, t2: c.struct_timespec) c_long {
    return (t1.tv_sec - t2.tv_sec) * 1000 + @divTrunc(t1.tv_nsec - t2.tv_nsec, 1_000_000);
}

pub inline fn LIMIT(
    comptime T: type,
    x: T,
    low: T,
    hi: T,
) T {
    return if (x < low) low else if (x > hi) hi else x;
}

inline fn get_colormap(conn: *c.xcb_connection_t) c.xcb_colormap_t {
    return c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data.*.default_colormap;
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
        const values: [3]u32 = .{
            fg,
            bg,
            0,
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

        const value_mask: u32 = c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND | c.XCB_GRAPHICS_EXPOSURE;
        const values: [3]u32 = .{
            fg,
            bg,
            0,
        };
        _ = c.xcb_change_gc(conn, out_gc, value_mask, &values);

        return out_gc;
    }
}

pub inline fn set_cardinal_property(
    conn: *c.xcb_connection_t,
    prop_name: []const u8,
    value: u32,
) void {
    const prop = get_atom(conn, prop_name);
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        prop,
        c.XCB_ATOM_CARDINAL,
        32,
        1,
        &value,
    );
}

//TODO:function for epoll events with getting fd from conn,MAKE ALL XCB CALLS CLEAR,MEMORY LEAKS NOW,CACHE atoms,change doc about windows
// esc commansd \e[2J to clear the screen, \e[H to move the cursor).
//

pub inline fn init_colors(
    conn: *c.xcb_connection_t,
    dc: *DC,
) void {
    set_bg(conn, dc.gc, dc.col[c.defaultbg].pixel);
    set_fg(conn, dc.gc, dc.col[c.defaultfg].pixel);
}

pub inline fn get_geometry_reply(xc: *c.xcb_connection_t, cookie: c.xcb_get_geometry_cookie_t) !TermWindow {
    const reply = c.xcb_get_geometry_reply(xc, cookie, null) orelse {
        std.log.err("Could not get geometry", .{});
        return error.CannotGetGeometry;
    };
    defer std.c.free(reply);
    const height = reply.*.height;
    return TermWindow{
        .mode = WinMode.initEmpty(),
        .tty_grid = Grid{ .cols = 0, .rows = 0 },
        .win_size = Size{ .width = reply.*.width, .height = height },
        .char_size = Size{ .width = 0, .height = 0 },
        .cursor = 0,
    };
}
pub inline fn get_geometry(xc: *c.xcb_connection_t, f: Font) !TermWindow {
    var geo = try get_geometry_reply(xc, c.xcb_get_geometry(xc, get_main_window(xc)));
    geo.win_size.width -= geo.win_size.width % f.size.width;
    geo.win_size.height -= geo.win_size.height % f.size.height;
    return geo;
}

// Resize window and its subwindows
pub fn resize_window(conn: *c.xcb_connection_t, f: Font) void {
    const geo = get_geometry(conn, f) catch |err| {
        std.log.err("Failed to get geometry: {}", .{err});
        return;
    };
    const vt_values = [_]u16{ geo.win_size.width, geo.win_size.height };
    _ = c.xcb_configure_window(conn, get_main_window(conn), c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &vt_values);
}

pub inline fn map_windows(
    conn: *c.xcb_connection_t,
    f: Font,
) void {
    _ = c.xcb_map_window(conn, get_main_window(conn));
    _ = c.xcb_map_subwindows(conn, get_main_window(conn));
    resize_window(conn, f);
}

pub inline fn set_windows_name(
    conn: *c.xcb_connection_t,
    win: c.xcb_window_t,
    name: []const u8,
) void {
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        win,
        c.XCB_ATOM_WM_NAME,
        c.XCB_ATOM_STRING,
        8,
        @intCast(name.len),
        name.ptr,
    );
}

inline fn set_icon_name(xc: *c.xcb_connection_t, win: c.xcb_window_t, name: []const u8) void {
    _ = c.xcb_change_property(
        xc,
        c.XCB_PROP_MODE_REPLACE,
        win,
        c.XCB_ATOM_WM_ICON_NAME,
        c.XCB_ATOM_STRING,
        8,
        @intCast(name.len),
        name.ptr,
    );
}

pub fn get_root_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.root_initialized) {
        const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;
        S.root_window = screen.*.root;
        S.root_initialized = true;
    }
    return S.root_window;
}

pub fn get_main_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.main_initialized) {
        S.main_window_id = c.xcb_generate_id(conn);
        S.main_initialized = true;
    }
    return S.main_window_id;
}

pub inline fn get_atom(
    conn: *c.xcb_connection_t,
    name: []const u8,
) c.xcb_atom_t {
    const r = c.xcb_intern_atom_reply(conn, c.xcb_intern_atom(
        conn,
        @intFromBool(false),
        @intCast(name.len),
        name.ptr,
    ), null);
    defer std.c.free(r);
    const a = r.*.atom;
    return a;
}

pub inline fn get_wm_del_win(
    conn: *c.xcb_connection_t,
) c.xcb_atom_t {
    const a = get_atom(conn, "WM_DELETE_WINDOW");
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, get_main_window(conn), get_atom(conn, "WM_PROTOCOLS"), c.XCB_ATOM_ATOM, 32, 1, &a);
    return a;
}

// pub inline fn open_font(
//     conn: *c.xcb_connection_t
//     font_id: c.xcb_font_t,
// ) bool {}

pub inline fn set_utf8_prop(
    conn: *c.xcb_connection_t,
    prop: c.xcb_atom_t,
    value: []const u8,
) void {
    const utf8 = get_atom(conn, "UTF8_STRING");
    // const prop = get_atom(conn, prop_name);
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        prop,
        utf8,
        8,
        @intCast(value.len),
        value.ptr,
    );
}

pub inline fn get_clipboard(
    conn: *c.xcb_connection_t,
) c.xcb_atom_t {
    const a = get_atom(conn, "CLIBOARD");
    return a;
}

pub inline fn set_property(
    conn: *c.xcb_connection_t,
    atom: c.xcb_atom_t,
    size: u32,
    value: *anyopaque,
) void {
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        atom,
        c.XCB_ATOM_STRING,
        8,
        size,
        value,
    );
}

// pub inline fn set_property(
//     conn: *c.xcb_connection_t,
//     prop_name: []const u8,
//     value: []const u8,
// ) void {
//     _ = c.xcb_change_property(
//         conn,
//         c.XCB_PROP_MODE_REPLACE,
//         get_main_window(conn),
//         get_atom(conn, prop_name),
//         c.XCB_ATOM_STRING,
//         8,
//         @intCast(value.len),

//         value.ptr,
//     );
// }

pub inline fn create_main_window(
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    win: TermWindow,
    values: []u32,
    mask: u32,
    visual: VisualData,
) void {
    const window = get_main_window(conn);
    const cookie = c.xcb_create_window_checked(
        conn,
        @intFromEnum(elements.COPY_FROM_PARENT),
        window,
        root,
        0,
        0,
        @intCast(win.win_size.width),
        @intCast(win.win_size.height),
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        visual.visual.*.visual_id,
        mask,
        values.ptr,
    );
    XlibTerminal.testCookie(cookie, conn, "cannot create main window");
}

pub inline fn get_cursor(
    conn: *c.xcb_connection_t,
    name: [*c]const u8,
) c.xcb_cursor_t {
    var ctx: ?*c.xcb_cursor_context_t = undefined;
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;

    _ = c.xcb_cursor_context_new(conn, screen, &ctx);
    const cursor: c.xcb_cursor_t = c.xcb_cursor_load_cursor(ctx, name);
    _ = c.xcb_cursor_context_free(ctx);
    return cursor;
}

pub inline fn set_cursor( //free
    conn: *c.xcb_connection_t,
    font_id: c.xcb_font_t,
) c.xcb_cursor_t {
    const cursor_id = c.xcb_generate_id(conn);
    errdefer _ = c.xcb_free_cursor(conn, cursor_id);
    _ = c.xcb_create_glyph_cursor(
        conn,
        cursor_id,
        font_id,
        font_id,
        c.CURSORSHAPE,
        c.CURSORSHAPE + 1,
        0xffff,
        0xffff,
        0xffff,
        0,
        0,
        0,
    );

    _ = c.xcb_change_window_attributes(
        conn,
        get_main_window(conn),
        c.XCB_CW_CURSOR,
        &cursor_id,
    );
    return cursor_id;
}

pub inline fn get_cmap_from_winattr(
    conn: *c.xcb_connection_t,
    wac: c.xcb_get_window_attributes_cookie_t,
) c.xcb_colormap_t {
    const reply: *c.xcb_get_window_attributes_reply_t = c.xcb_get_window_attributes_reply(conn, wac, null);
    const cmap: c.xcb_colormap_t = reply.colormap;
    std.c.free(reply);
    return cmap;
}

// pub inline fn set_fg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
//     _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &[_]u32{p});
//     return p;
// }

pub inline fn set_fg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    p: u32,
) void {
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_FOREGROUND, &[_]u32{p});
    XlibTerminal.testCookie(cookie, conn, "cannot set foreground color");
}

pub inline fn set_bg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    p: u32,
) void {
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_BACKGROUND, &[_]u32{p});
    XlibTerminal.testCookie(cookie, conn, "cannot set background color");
}
// pub inline fn set_bg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
//     _ = c.xcb_change_gc(conn, gc, c.XCB_GC_BACKGROUND, &[_]u32{p});
//     return p;
// }

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

pub inline fn get_pixel(
    conn: *c.xcb_connection_t,
    cmap: c.xcb_colormap_t,
    color: []const u8,
) u32 {
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
    //========main struct=========//=
    connection: *c.xcb_connection_t,
    //============================//=
    screen: *c.xcb_screen_t,
    pixmap: c.xcb_pixmap_t,
    allocator: Allocator,
    pty: justty.Pty,
    pid: posix.pid_t,
    visual: VisualData,
    cursor: c.xcb_cursor_t,
    cursor_font: c.xcb_font_t,
    ft: font.FreeType,
    fc: font.Fontconfig,

    dc: DC,
    output: [1024]u8 = undefined, // Buffer to store pty output
    win: TermWindow,
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
        const visual_data = try VisualData.init(screen);
        if (comptime util.isDebug) {
            std.log.info("Visual depth: {}, visual_id: {}", .{ visual_data.visual_depth, visual_data.visual.visual_id });
        }

        // const screen = c.XDefaultScreen(display);
        const root = get_root_window(connection);

        // const visual = screen.*.root_visual;
        //====================================font ===============================//
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

        const face = try font.Face.init(ft, file);

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

        const metrics = face.handle.*.size.*.metrics;
        const cw = @as(u16, @intCast((metrics.max_advance + 63) >> 6));
        const ch = @as(u16, @intCast((metrics.height + 63) >> 6));
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
        var border_px = @as(u16, @intCast(c.borderpx)); // u16
        const cols_u16 = @as(u16, @intCast(c.cols)); // u8
        const rows_u16 = @as(u16, @intCast(c.rows)); // u8
        if (border_px == 0) {
            border_px = 1;
        }

        var win: TermWindow = .{
            .mode = WinMode.initEmpty(),
            .tty_grid = Grid{ .cols = cols_u16, .rows = rows_u16 },
            .win_size = Size{ .width = 2 * border_px + cols_u16 * cw, .height = 2 * border_px + rows_u16 * ch },
            .char_size = Size{ .width = cw, .height = ch },
            .cursor = c.CURSORSHAPE,
        };
        // win.mode = WinMode.initEmpty();
        // win.tty_size = .
        // win.tw = cols_u16;
        // win.th = rows_u16;
        // win.cw = cw;
        // win.ch = ch;
        // win.w = @as(u16, 2 * border_px + cols_u16 * cw);
        // win.h = @as(u16, 2 * border_px + rows_u16 * ch);
        // .cursor = c.mouseshape,
        var dc: DC = undefined;
        errdefer _ = c.xcb_free_gc(connection, dc.gc);
        win.mode.set(@intFromEnum(WinModeFlags.MODE_NUMLOCK));
        if (comptime util.isDebug) {
            if (win.mode.isSet(@intFromEnum(WinModeFlags.MODE_NUMLOCK))) {
                std.log.info("Window is numlock", .{});
            }
        }
        // dc.col = try allocator.alloc(c.XftColor, dc.len); //alloc

        dc.font = .{
            .size = Size{ .width = cw, .height = ch },
            .ascent = @intCast(ascent),
            .face = face,
        };

        for (&dc.col, 0..) |*color, i| {
            if (!xloadcolor(connection, visual_data.visual, i, null, color)) {
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

        const window = get_main_window(connection);

        errdefer _ = c.xcb_destroy_window(
            connection,
            root,
        );
        var values_main = [_]u32{
            dc.col[c.defaultbg].pixel,
            c.XCB_EVENT_MASK_EXPOSURE |
                c.XCB_EVENT_MASK_KEY_PRESS |
                c.XCB_EVENT_MASK_KEY_RELEASE |
                c.XCB_EVENT_MASK_BUTTON_PRESS |
                c.XCB_EVENT_MASK_BUTTON_RELEASE |
                c.XCB_EVENT_MASK_BUTTON_MOTION |
                c.XCB_EVENT_MASK_FOCUS_CHANGE |
                c.XCB_EVENT_MASK_VISIBILITY_CHANGE |
                c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                masks.CHILD_EVENT_MASK,
        };

        create_main_window(
            connection,
            root,
            win,
            values_main[0..],
            masks.WINDOW_WM,
            visual_data,
        );

        const pixmap = c.xcb_generate_id(connection);

        _ = c.xcb_create_pixmap(
            connection,
            visual_data.visual_depth,
            pixmap,
            window,
            win.win_size.width,
            win.win_size.height,
        );
        errdefer _ = c.xcb_free_pixmap(connection, pixmap);
        //========================cursor =================//
        const xcb_font: c.xcb_font_t = c.xcb_generate_id(connection);
        // const cursor: c.xcb_cursor_t = get_cursor(connection, "xterm");
        const cursor = set_cursor(connection, xcb_font);
        defer _ = c.xcb_free_cursor(connection, cursor);

        //==================gc values=====================//
        // const gc = c.xcb_generate_id(connection);
        dc.gc = c.xcb_generate_id(connection);
        dc.gc = create_gc(connection, dc.gc, get_main_window(connection), dc.col[c.defaultfg].pixel, dc.col[c.defaultbg].pixel);
        errdefer _ = c.xcb_free_gc(connection, dc.gc);
        // _ = c.xcb_poly_fill_rectangle(
        //     connection,
        //     pixmap,
        //     dc.gc,
        //     0,
        //     &[_]c.xcb_rectangle_t{
        //         .{
        //             .x = 0,
        //             .y = 0,
        //             .width = win.w,
        //             .height = win.h,
        //         },
        //     },
        // );
        //
        _ = c.xcb_poly_fill_rectangle(connection, pixmap, dc.gc, 0, &[_]c.xcb_rectangle_t{
            .{
                .x = 0,
                .y = 0,
                .width = win.win_size.width,
                .height = win.win_size.height,
            },
        });
        // ================drawable =======================//
        // const draw = c.XftDrawCreate(display, buf, visual, cmap);
        //
        // const draw = c.XftDrawCreate(display, buf, visual, cmap) orelse return error.CannotCreateDraw;
        //================= inputs TODO:FINISH INPUT METHODS //
        // _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

        const initial_size: justty.winsize = .{ .ws_row = c.rows, .ws_col = c.cols, .ws_xpixel = 0, .ws_ypixel = 0 };

        // const atom_names = [_][]const u8{ "_XEMBED", "WM_DELETE_WINDOW", "_NET_WM_NAME", "_NET_WM_ICON_NAME", "_NET_WM_PID" };
        // var atoms: Atoms = undefined;
        // for (atom_names, 0..) |name, i| {
        //     const cookie = c.xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr);
        //     const reply = c.xcb_intern_atom_reply(connection, cookie, null) orelse return error.CannotInternAtom;
        //     defer std.c.free(reply);
        //     switch (i) {
        //         0 => atoms.xembed = reply.*.atom,
        //         1 => atoms.wmdeletewin = reply.*.atom,
        //         2 => atoms.netwmname = reply.*.atom,
        //         3 => atoms.netwmiconname = reply.*.atom,
        //         4 => atoms.netwmpid = reply.*.atom,
        //         else => unreachable,
        //     }
        // }

        const atom_del = get_wm_del_win(connection);
        // const pid_atom = get_atom(connection, "_NET_WM_PID");
        // set_property(connection, "_NET_WM_PID", value: []const u8)
        //==================atom ======================//
        //============================================//
        set_windows_name(connection, get_main_window(connection), "justty");
        set_icon_name(connection, get_main_window(connection), "justty");
        var pty = try justty.Pty.open(initial_size);

        errdefer pty.deinit();
        const pid = try posix.fork();
        // set_cardinal_property(connection, "_NET_WM_PID", @intCast(pid));
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            root,
            atom_del,
            c.XCB_ATOM_ATOM,
            32,
            1,
            &atom_del,
        );
        // set_property(conn: *c.xcb_connection_t, prop_name: []const u8, value: []const u8)
        try pty.exec(pid);
        map_windows(connection, dc.font);
        _ = c.xcb_flush(connection);

        return .{
            .visual = visual_data,
            // .attrs = attrs,
            // .gc_values = gcvalues,
            .connection = connection,
            .screen = screen,
            // .window = root,
            .pixmap = pixmap,
            .cursor = cursor,
            .cursor_font = xcb_font,
            .ft = ft,
            .fc = fc,
            .allocator = allocator,
            .pty = pty,
            .pid = pid,
            // .atoms = atoms,
            .dc = dc,
            .win = win,
        };
    }

    inline fn sixd_to_16bit(x: u3) u16 {
        return @as(u16, @intCast(if (x == 0) 0 else 0x3737 + 0x2828 * @as(u16, @intCast(x))));
    }

    inline fn xloadcolor(
        conn: *c.xcb_connection_t,
        // screen: *c.xc_screen_t,
        visual: *c.xcb_visualtype_t,
        i: usize,
        color_name: ?[*:0]const u8,
        color: *Color,
    ) bool {
        const name = color_name orelse blk: {
            if (16 <= i and i <= 255) {
                var xcolor: RenderColor = .{
                    .alpha = 0xffff,
                    .red = 0,
                    .green = 0,
                    .blue = 0,
                };

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
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
            }
            break :blk c.colorname[i];
        };

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
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
            } else |_| {
                return false;
            }
        }

        return color_alloc_name(
            conn,
            get_colormap(conn),
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
        const event_type = event.response_type & ~@as(u8, 0x80);
        switch (event_type) {
            c.XCB_EXPOSE => {
                const expose_event = @as(*c.xcb_expose_event_t, @ptrCast(event));
                if (expose_event.window == get_main_window(self.connection)) {
                    try self.redraw();
                }
            },
            c.XCB_KEY_PRESS => {
                const key_event = @as(*c.xcb_key_press_event_t, @ptrCast(event));
                if (key_event.event == get_main_window(self.connection)) {
                    const keysym = key_event.detail;
                    if (keysym >= 32 and keysym <= 126) {
                        const char = @as(u8, @intCast(keysym));
                        _ = posix.write(self.pty.master, &[_]u8{char}) catch {};
                        try self.redraw();
                    }
                }
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const config_event = @as(*c.xcb_configure_notify_event_t, @ptrCast(event));
                if (config_event.window == get_main_window(self.connection)) {
                    const new_size = justty.winsize{
                        .ws_row = @intCast(@divTrunc(config_event.height, @as(u16, @intCast(self.dc.font.size.height)))),
                        .ws_col = @intCast(@divTrunc(config_event.width, @as(u16, @intCast(self.dc.font.size.width)))),
                        .ws_xpixel = 0,
                        .ws_ypixel = 0,
                    };
                    self.pty.resize(new_size) catch {};
                }
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

    inline fn redraw(self: *Self) !void {
        const width = @as(u32, @intCast(self.win.win_size.width));
        const height = @as(u32, @intCast(self.win.win_size.height));
        const buffer = try self.allocator.alloc(u32, width * height);
        if (comptime util.isDebug) {
            if (self.dc.col[c.defaultbg].pixel == 0) {
                std.log.err("Background color not allocated!", .{});
                return error.InvalidBackgroundColor;
            }
        }
        defer self.allocator.free(buffer);
        @memset(buffer, self.dc.col[c.defaultbg].pixel);

        var y: i32 = @intCast(self.dc.font.ascent);
        var start: usize = 0;
        while (start < self.output_len) {
            var end = start;
            while (end < self.output_len and self.output[end] != '\n') end += 1;

            var x: i32 = 10;
            for (self.output[start..end]) |char| {
                const glyph_index = self.dc.font.face.getCharIndex(char) orelse continue;
                self.dc.font.face.loadGlyph(glyph_index, .{
                    .render = true,
                }) catch continue;
                self.dc.font.face.renderGlyph(.mono) catch continue;

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
                                const buf_x = @as(u32, @intCast(x + bitmap_left + @as(i32, @intCast(px))));
                                const buf_y = @as(u32, @intCast(y - bitmap_top + @as(i32, @intCast(py))));
                                if (buf_x < width and buf_y < height) {
                                    buffer[buf_y * width + buf_x] = self.dc.col[c.defaultfg].pixel;
                                }
                            }
                        }
                    }
                }
                x += @intCast(self.dc.font.face.handle.*.glyph.*.advance.x >> 6);
            }
            y += @intCast(self.dc.font.size.height);
            start = end + 1;
            if (y > @as(i32, @intCast(height))) break;
        }

        const cursor_x = 10;
        const cursor_y = 10;
        const cursor_width = 2;
        const cursor_height = self.dc.font.size.height;
        for (cursor_y..cursor_y + cursor_height) |cy| {
            for (cursor_x..cursor_x + cursor_width) |cx| {
                if (cx < width and cy < height) {
                    buffer[cy * width + cx] = self.dc.col[c.defaultcs].pixel;
                }
            }
        }

        const data = @as([*]const u8, @ptrCast(buffer.ptr))[0 .. width * height * 4];
        const image_cookie = c.xcb_put_image_checked(
            self.connection,
            c.XCB_IMAGE_FORMAT_Z_PIXMAP,
            self.pixmap,
            self.dc.gc,
            @intCast(width),
            @intCast(height),
            0,
            0,
            0,
            self.screen.*.root_depth,
            @intCast(width * height * 4),
            data.ptr,
        );
        testCookie(image_cookie, self.connection, "cannot put image");

        const vt_window = get_main_window(self.connection);
        _ = c.xcb_copy_area(
            self.connection,
            self.pixmap,
            vt_window,
            self.dc.gc,
            0,
            0,
            0,
            0,
            self.win.win_size.width,
            self.win.win_size.height,
        );

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
        _ = c.xcb_destroy_window(self.connection, self.screen.*.root);
        _ = c.xcb_disconnect(self.connection);
    }
};
