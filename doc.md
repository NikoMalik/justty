# justty.zig:


  Terminal Emulator (Parent Process)
  Master: Used by the parent (terminal emulator) to send input to and receive output from the child.
  Slave: Used by the child (shell) to receive input and send output, acting as its terminal.
   |
   |--- Holds self.master (fd)
   |      |
   |      |--- Write: Sends input (e.g., "ls\n") to child
   |      |--- Read: Receives output (e.g., "file1 file2\n") from child
   |
   |--- Forks child process
   |
 Shell (Child Process)
   |
   |--- Uses self.slave (fd, redirected to STDIN/STDOUT/STDERR)
   |      |
   |      |--- Read: Receives input from parent (via master)
   |      |--- Write: Sends output to parent (via master)

 Master:
 The master end is a file descriptor used by the parent process (e.g., your terminal emulator).
 It acts as the controlling side of the PTY, allowing the parent to:
     Write data to the PTY, which appears as input to the child process (e.g., typing commands in the terminal).
     Read data from the PTY, which is the output produced by the child process (e.g., command output like ls or echo).
 The master is typically held open by the terminal emulator to interact with the child process running in the PTY.


 Slave:
 The slave end is a file descriptor used by the child process (e.g., a shell like bash or zsh).
 It acts as the terminal device for the child, behaving like a real terminal (e.g., /dev/tty).
 The child process:
     Reads from the slave to get input (e.g., user commands sent via the master).
     Writes to the slave to produce output (e.g., command results, which are then read by the master).
 The slave is redirected to the child’s standard input (STDIN), output (STDOUT), and error (STDERR) via dup2 in my exec function.






# x.zig:
*root window - its This is the root window of the X11 display, covering the entire screen.
 It is controlled by the window manager and serves as a parent for all other windows in the application.
It is not directly involved in rendering, but provides a coordinate system and context for other windows.

*main_window The main terminal window containing design elements (title bar, frames) that are usually added by the window manager.
 It is the parent of vt_window.
//Responsible for interaction with the window manager (e.g. resize, move, focus).
 (text, cursor) are displayed and user inputs (keys, mouse) are processed

root_window *width propery and more*
└── main_window *text, cursor,visual8

