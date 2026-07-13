#+build linux, darwin, freebsd, openbsd, netbsd
package grotti

// Interactivity + color enabling on POSIX systems (Linux, macOS, the BSDs). The `_unix`
// filename suffix restricts this file to non-Windows targets; the Windows twin lives in
// console_tty_windows.odin. Keeping the posix import out of console.odin is what lets the
// package cross-compile to windows_amd64.

import "core:os"
import "core:sys/posix"

@(private)
_stdout_is_tty :: proc() -> bool {
	return bool(posix.isatty(posix.FD(os.fd(os.stdout))))
}

@(private)
_enable_ansi :: proc() {
	// POSIX terminals interpret ANSI SGR natively — nothing to enable.
}

@(private)
_enable_utf8 :: proc() {
	// POSIX terminals are UTF-8 by locale — there is no console code page to switch.
}

@(private)
_restore_console :: proc() {
	// Nothing was changed on POSIX; the Windows twin restores its saved code page.
}
