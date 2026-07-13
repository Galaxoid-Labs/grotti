#+build linux, darwin, freebsd, openbsd, netbsd
package main

// Ctrl-C handling on POSIX: SIGINT sets the global quit flag, which stops Fenja and every
// worker. The `_unix` suffix keeps this off Windows (see signal_windows.odin).

import "base:intrinsics"
import "core:sys/posix"

@(private)
_sigint_handler :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store_explicit(&g_quit, 1, .Release)
}

install_interrupt_handler :: proc() {
	posix.signal(posix.Signal(posix.SIGINT), _sigint_handler)
}
