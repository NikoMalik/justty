pub usingnamespace @cImport({
    @cInclude("sys/ioctl.h");
    // @cInclude("sys/mman.h");
    @cInclude("sys/select.h");
    @cInclude("sys/stat.h"); // @cInclude("sys/shm.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcb_cursor.h");
    @cInclude("xcb/xcb_keysyms.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xcb/xcb_image.h");
    @cInclude("xcb/xcb_renderutil.h");
    @cInclude("xcb/xcb_xrm.h");
    @cInclude("xcb/render.h");
    @cInclude("pixman.h");
    @cInclude("locale.h");
    @cInclude("config.h");
    // @cInclude("ft2build.h");
    @cInclude("fontconfig/fontconfig.h");
    // @cInclude("X11/Xlib-xcb.h");
    @cInclude("freetype/ftmm.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftsnames.h");
    @cInclude("freetype/ttnameid.h");

    //fcft
    // @cInclude("fcft/stride.h");
    // @cInclude("fcft/fcft.h");
});

//     for (data) |byte| {
//         if (self.esc_len >= self.esc_buf.len) {
//             std.log.warn("Escape sequence buffer overflow: {x}", .{self.esc_buf[0..self.esc_len]});
//             self.esc = 0;
//             self.esc_len = 0;
//             continue;
//         }

//         self.esc_buf[self.esc_len] = byte;
//         self.esc_len += 1;

//         std.log.debug("ESC buffer: {x}", .{self.esc_buf[0..self.esc_len]});

//         if (self.esc_len >= 2 and self.esc_buf[0] == 0x1B and self.esc_buf[1] == '[') {
//             if (self.esc_len > 2 and (byte >= '@' and byte <= '~')) {
//                 var params: [esc_arg_size]u32 = undefined;
//                 var param_count: usize = 0;
//                 const sequence = self.esc_buf[0..self.esc_len];
//                 const end_char = byte;

//                 if (self.esc_len > 3) {
//                     const param_str = sequence[2 .. self.esc_len - 1];
//                     var start: usize = 0;
//                     while (start < param_str.len) {
//                         const end = for (start..param_str.len) |i| {
//                             if (param_str[i] == ';') break i;
//                         } else param_str.len;
//                         if (start < end and param_count < params.len) {
//                             const num_str = param_str[start..end];
//                             params[param_count] = std.fmt.parseInt(u32, num_str, 10) catch 0;
//                             param_count += 1;
//                         }
//                         start = end + 1;
//                     }
//                 } else if (param_count < params.len) {
//                     params[param_count] = 0;
//                     param_count += 1;
//                 }

//                 std.log.debug("Parsed CSI: params={any}, end_char={c}", .{ params[0..param_count], end_char });

//                 const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
//                 const old_y = self.cursor.pos.y;
//                 switch (end_char) {
//                     'm' => {
//                         self.handle_sgr(params[0..param_count]);
//                         self.set_dirt(self.cursor.pos.y, self.cursor.pos.y);
//                     },
//                     'J' => {
//                         const n = if (param_count > 0) params[0] else 0;
//                         switch (n) {
//                             0 => {
//                                 for (self.cursor.pos.y..self.size_grid.rows) |y| {
//                                     for (if (y == self.cursor.pos.y) self.cursor.pos.x else 0..self.size_grid.cols) |x| {
//                                         screen[y][x] = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                     }
//                                     self.set_dirt(@intCast(y), @intCast(y));
//                                 }
//                             },
//                             1 => {
//                                 for (0..self.cursor.pos.y + 1) |y| {
//                                     for (0..(if (y == self.cursor.pos.y) self.cursor.pos.x + 1 else self.size_grid.cols)) |x| {
//                                         screen[y][x] = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                     }
//                                     self.set_dirt(@intCast(y), @intCast(y));
//                                 }
//                             },
//                             2 => {
//                                 for (screen[0..self.size_grid.rows]) |*row| {
//                                     for (row[0..self.size_grid.cols]) |*glyph| {
//                                         glyph.* = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                     }
//                                 }
//                                 self.fulldirt();
//                             },
//                             else => std.log.warn("Unsupported ED parameter: {}", .{n}),
//                         }
//                     },
//                     'K' => {
//                         const n = if (param_count > 0) params[0] else 0;
//                         const y = self.cursor.pos.y;
//                         switch (n) {
//                             0 => {
//                                 for (self.cursor.pos.x..self.size_grid.cols) |x| {
//                                     screen[y][x] = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                 }
//                                 self.set_dirt(y, y);
//                             },
//                             1 => {
//                                 for (0..self.cursor.pos.x + 1) |x| {
//                                     screen[y][x] = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                 }
//                                 self.set_dirt(y, y);
//                             },
//                             2 => {
//                                 for (0..self.size_grid.cols) |x| {
//                                     screen[y][x] = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
//                                 }
//                                 self.set_dirt(y, y);
//                             },
//                             else => std.log.warn("Unsupported EL parameter: {}", .{n}),
//                         }
//                     },
//                     'H' => {
//                         const row = if (param_count > 0) @max(1, params[0]) else 1;
//                         const col = if (param_count > 1) @max(1, params[1]) else 1;
//                         const new_y = @min(@as(u16, @intCast(row - 1)), self.size_grid.rows - 1);
//                         const new_x = @min(@as(u16, @intCast(col - 1)), self.size_grid.cols - 1);
//                         self.set_dirt(old_y, old_y);
//                         self.cursor.pos = Position{ .x = new_x, .y = new_y };
//                         self.set_dirt(self.cursor.pos.y, self.cursor.pos.y);
//                     },
//                     'h', 'l' => {
//                         if (self.esc_len > 3 and self.esc_buf[2] == '?') {
//                             const param = if (param_count > 0) params[0] else 0;
//                             if (param == 1049) {
//                                 if (end_char == 'h') {
//                                     self.mode.set(.MODE_ALTSCREEN);
//                                     self.fulldirt();
//                                 } else {
//                                     self.mode.unset(.MODE_ALTSCREEN);
//                                     self.fulldirt();
//                                 }
//                             } else {
//                                 std.log.debug("Unhandled mode param: {}", .{param});
//                             }
//                         }
//                     },
//                     else => {
//                         std.log.debug("Unhandled CSI end char: {c}", .{end_char});
//                     },
//                 }
//                 self.esc = 0;
//                 self.esc_len = 0;
//             }
//         } else if (self.esc_len > 32) {
//             std.log.warn("Incomplete escape sequence, resetting: {x}", .{self.esc_buf[0..self.esc_len]});
//             self.esc = 0;
//             self.esc_len = 0;
//         }
//     }
// }
