*root window - its This is the root window of the X11 display, covering the entire screen.
 It is controlled by the window manager and serves as a parent for all other windows in the application.
It is not directly involved in rendering, but provides a coordinate system and context for other windows.

*main_window The main terminal window containing design elements (title bar, frames) that are usually added by the window manager.
 It is the parent of vt_window.
//Responsible for interaction with the window manager (e.g. resize, move, focus).
 (text, cursor) are displayed and user inputs (keys, mouse) are processed

root_window *width propery and more*
└── main_window *text, cursor,visual8

