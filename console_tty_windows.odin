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

// The console's output code page must be UTF-8 or the box-drawing / status glyphs Grotti
// emits (◆ · ✔ ✘ —) render as mojibake — the legacy OEM page reads each multi-byte UTF-8
// sequence as separate garbage characters. This is independent of color, so console_init
// calls it for any real console, not just when SGR is on. But the code page is
// process-wide and PERSISTS after we exit (it belongs to the shared console, not this
// process), so we save the previous page and _restore_console puts it back on shutdown.
@(private)
_saved_output_cp: win.CODEPAGE
@(private)
_output_cp_changed: bool

@(private)
_enable_utf8 :: proc() {
	prev := win.GetConsoleOutputCP()
	if prev == win.CODEPAGE.UTF8 {
		return // already UTF-8 (e.g. Windows Terminal default) — nothing to change or restore
	}
	if win.SetConsoleOutputCP(win.CODEPAGE.UTF8) != win.FALSE {
		_saved_output_cp = prev
		_output_cp_changed = true
	}
}

@(private)
_restore_console :: proc() {
	if _output_cp_changed {
		win.SetConsoleOutputCP(_saved_output_cp)
		_output_cp_changed = false
	}
}
