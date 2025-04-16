const std = @import("std");
const c = @import("c.zig");

fn example() void {
    const display: ?*c.Display = c.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Failed to open X display\n", .{});
        return;
    }

    const screen = c.DefaultScreen(display);
    const root_window = c.DefaultRootWindow(display);

    const window = c.XCreateSimpleWindow(
        display,
        root_window,
        200, // x
        300, // y
        350, // width
        250, // height
        5, // border_width
        c.BlackPixel(display, screen), // border color
        c.WhitePixel(display, screen), // background color
    );

    _ = c.XStoreName(display, window, "Zig X11 Test");

    _ = c.XMapWindow(display, window);

    var event: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(display, &event);

        if (event.type == c.KeyPress)
            break;
    }

    _ = c.XCloseDisplay(display);
}
