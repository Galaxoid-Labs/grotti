package grotti

// Interactivity + color enabling on Windows. Console detection is "does stdout have a
// console mode"; ANSI SGR requires opting into virtual-terminal processing (Win10+), which
// _enable_ansi does once at startup. The `_windows` suffix restricts this file to Windows;
// the POSIX twin is console_tty_unix.odin.

import win "core:sys/windows"

@(private)
_stdout_is_tty :: proc() -> bool {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	mode: win.DWORD
	return win.GetConsoleMode(h, &mode) != win.FALSE
}

@(private)
_enable_ansi :: proc() {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	mode: win.DWORD
	if win.GetConsoleMode(h, &mode) != win.FALSE {
		win.SetConsoleMode(h, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
	}
}
