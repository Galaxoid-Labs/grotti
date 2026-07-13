package grotti

// Console output — the two-channel, theme-aware, color-gated rendering from
// CLAUDE.md § Console output. An operator must be able to see, at a glance, the two
// things that matter: am I about to brick the chain, and are my shares landing.
//
// Formatting lives here; the stone never calls it (invariant #3). Every renderer is
// a pure function of a Console + fields into a strings.Builder, so the output is
// unit-tested with color on and off rather than eyeballed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Color_Mode :: enum {
	Auto,
	Always,
	Never,
}

Console :: struct {
	color: bool, // emit ANSI SGR codes
	tty:   bool, // stdout is interactive → repainting status line is allowed
}

// console_init resolves color and interactivity. Color needs ALL of: a TTY, NO_COLOR
// unset, TERM != dumb (unless forced). The same TTY decision gates the repainting
// status line, so piped output is always clean plain text.
console_init :: proc(mode: Color_Mode) -> (c: Console) {
	c.tty = _stdout_is_tty()
	switch mode {
	case .Always:
		c.color = true
	case .Never:
		c.color = false
	case .Auto:
		c.color = c.tty && !_env_set("NO_COLOR") && _term() != "dumb"
	}
	// On Windows a console needs its output code page set to UTF-8 or Grotti's glyphs
	// (◆ · ✔ ✘ —) render as mojibake; this is independent of color, so it runs for any
	// real console. ANSI SGR additionally needs virtual-terminal processing opted in.
	// Both are no-ops on POSIX. Defined per-OS in console_tty_{unix,windows}.odin. Pair
	// console_init with console_restore at shutdown so the code page is put back.
	if c.tty {
		_enable_utf8()
	}
	if c.color {
		_enable_ansi()
	}
	return
}

// console_restore undoes any process-wide console state console_init changed (on Windows,
// the output code page). Call it once on shutdown. A no-op on POSIX and when unchanged.
console_restore :: proc() {
	_restore_console()
}

@(private = "file")
_env_set :: proc(key: string) -> bool {
	// NOTE: lookup_env_buf returns err==nil even for an UNSET variable, so it cannot
	// tell "present" from "absent". lookup_env_alloc returns a real `found` boolean.
	_, found := os.lookup_env_alloc(key, context.temp_allocator)
	return found
}

@(private = "file")
_term :: proc() -> string {
	v, found := os.lookup_env_alloc("TERM", context.temp_allocator)
	return found ? v : ""
}

// --- color codes (SGR) ------------------------------------------------------

DIM :: "2"
RED :: "31"
GREEN :: "32"
YELLOW :: "33"
CYAN :: "36"
BOLD_CYAN :: "1;36"
BOLD_RED :: "1;31"
BOLD_GREEN :: "1;32"

@(private)
paint :: proc(b: ^strings.Builder, color: bool, code: string, text: string) {
	if color {
		strings.write_string(b, "\x1b[")
		strings.write_string(b, code)
		strings.write_byte(b, 'm')
		strings.write_string(b, text)
		strings.write_string(b, "\x1b[0m")
	} else {
		strings.write_string(b, text)
	}
}

// human_hps renders a hashrate with a sensible unit.
human_hps :: proc(b: ^strings.Builder, hps: f64) {
	switch {
	case hps >= 1e9:
		fmt.sbprintf(b, "%.2f GH/s", hps / 1e9)
	case hps >= 1e6:
		fmt.sbprintf(b, "%.2f MH/s", hps / 1e6)
	case hps >= 1e3:
		fmt.sbprintf(b, "%.2f KH/s", hps / 1e3)
	case:
		fmt.sbprintf(b, "%.0f H/s", hps)
	}
}

// --- event log --------------------------------------------------------------

// format_event writes one timestamped, tagged log line: "HH:MM:SS  tag   message".
// The timestamp and tag columns are dim; the tag keeps its own color.
format_event :: proc(b: ^strings.Builder, c: Console, h, m, s: int, tag_code, tag, message: string) {
	ts := fmt.tprintf("%02d:%02d:%02d", h, m, s)
	paint(b, c.color, DIM, ts)
	strings.write_string(b, "  ")
	paint(b, c.color, tag_code, fmt.tprintf("%-6s", tag))
	strings.write_byte(b, ' ')
	strings.write_string(b, message)
}

// format_share renders a share result. The whole thing goes green when accepted and
// red when rejected (reason included), so a run that is silently rejecting every
// share — the classic word-swapped-prevhash bug — looks alarming, not calm.
format_share :: proc(b: ^strings.Builder, c: Console, h, m, s: int, seq: int, accepted: bool, diff: f64, job: string, reason := "") {
	msg := strings.builder_make()
	defer strings.builder_destroy(&msg)
	if accepted {
		fmt.sbprintf(&msg, "#%d ✔ accepted  %.4f  (job %s)", seq, diff, job)
		body := strings.to_string(msg)
		format_event(b, c, h, m, s, GREEN, "share", "")
		paint(b, c.color, GREEN, body)
	} else {
		fmt.sbprintf(&msg, "#%d ✘ rejected  %s  (job %s)", seq, reason, job)
		body := strings.to_string(msg)
		format_event(b, c, h, m, s, RED, "share", "")
		paint(b, c.color, RED, body)
	}
}

// --- live status line -------------------------------------------------------

// human_duration renders a rough expected time (seconds) as s / m / h / d.
human_duration :: proc(b: ^strings.Builder, seconds: f64) {
	switch {
	case seconds < 90:
		fmt.sbprintf(b, "%.0fs", seconds)
	case seconds < 5400:
		fmt.sbprintf(b, "%.0fm", seconds / 60)
	case seconds < 172800:
		fmt.sbprintf(b, "%.1fh", seconds / 3600)
	case:
		fmt.sbprintf(b, "%.1fd", seconds / 86400)
	}
}

// format_status builds the repainting status line (no newline; the caller prefixes
// '\r' on a TTY). The hashrate is the headline number (bold cyan). `eta`, if given,
// is an already-formatted expected-time note (e.g. "share ~7m · block ~2.5d").
format_status :: proc(b: ^strings.Builder, c: Console, snap: Snapshot, hps: f64, job: string, eta := "") {
	strings.write_string(b, "◆ ")
	rate := strings.builder_make()
	defer strings.builder_destroy(&rate)
	human_hps(&rate, hps)
	paint(b, c.color, BOLD_CYAN, strings.to_string(rate))

	strings.write_string(b, "  ·  shares ")
	paint(b, c.color, GREEN, fmt.tprintf("%d✔", snap.accepted))
	strings.write_byte(b, ' ')
	paint(b, c.color, snap.rejected > 0 ? RED : DIM, fmt.tprintf("%d✘", snap.rejected))
	fmt.sbprintf(b, " (%.1f%%)", 100 * stats_acceptance_rate(snap))

	fmt.sbprintf(b, "  ·  up %s", _hms(snap.uptime_s))
	if len(job) > 0 {
		fmt.sbprintf(b, "  ·  job %s", job)
	}
	if len(eta) > 0 {
		fmt.sbprintf(b, "  ·  %s", eta)
	}
}

@(private = "file")
_hms :: proc(seconds: f64) -> string {
	total := int(seconds)
	return fmt.tprintf("%02d:%02d", total / 60, total % 60)
}

// --- startup safety block ---------------------------------------------------

// format_safety_block is the load-bearing startup panel (CLAUDE.md § 2). It states
// the cap as an absolute rate AND as a multiple of network hashrate — the ×network
// figure is the one that matters, and it turns bold-red the moment it exceeds 1.0.
format_safety_block :: proc(b: ^strings.Builder, c: Console, net_hps, difficulty, cap_hps, est_uncapped_hps: f64) {
	strings.write_string(b, "  chain safety\n")

	net := strings.builder_make();defer strings.builder_destroy(&net)
	human_hps(&net, net_hps)
	fmt.sbprintf(b, "    network        %-11s difficulty %.4f\n", strings.to_string(net), difficulty)

	_safety_row(b, c, "your cap", cap_hps, net_hps, cap_hps <= 0)
	_safety_row(b, c, "uncapped est.", est_uncapped_hps, net_hps, true)
}

@(private = "file")
_safety_row :: proc(b: ^strings.Builder, c: Console, label: string, hps, net_hps: f64, is_estimate: bool) {
	rate := strings.builder_make();defer strings.builder_destroy(&rate)
	if hps <= 0 && !is_estimate {
		strings.write_string(&rate, "UNCAPPED")
	} else {
		human_hps(&rate, hps)
	}
	ratio := net_hps > 0 ? hps / net_hps : 0

	fmt.sbprintf(b, "    %-14s %-11s ", label, strings.to_string(rate))

	x := fmt.tprintf("%.2f× network", ratio)
	danger := ratio > 1.0 || (hps <= 0 && !is_estimate)
	if is_estimate {
		// The uncapped estimate is informational; red only when it would be unsafe.
		paint(b, c.color, danger ? BOLD_RED : DIM, x)
		if danger {
			paint(b, c.color, DIM, "   needs --i-know-what-im-doing")
		}
	} else if danger {
		paint(b, c.color, BOLD_RED, x)
		paint(b, c.color, DIM, "   refuses without --i-know-what-im-doing")
	} else {
		paint(b, c.color, GREEN, x)
		paint(b, c.color, GREEN, "   OK, governed")
	}
	strings.write_byte(b, '\n')
}

// --- convenience: print helpers on real stdout ------------------------------

// wall_clock returns the local H:M:S for a live log line.
wall_clock :: proc() -> (h, m, s: int) {
	return time.clock_from_time(time.now())
}
