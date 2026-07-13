package main

// Ctrl-C handling on Windows: a console control handler sets the global quit flag, which
// stops Fenja and every worker. Returning TRUE marks the event handled. The `_windows`
// suffix keeps this off POSIX targets (see signal_unix.odin).

import "base:intrinsics"
import win "core:sys/windows"

@(private)
_ctrl_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	intrinsics.atomic_store_explicit(&g_quit, 1, .Release)
	return win.TRUE
}

install_interrupt_handler :: proc() {
	win.SetConsoleCtrlHandler(_ctrl_handler, win.TRUE)
}
