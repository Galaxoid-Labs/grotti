package grotti

import "core:strings"
import "core:testing"

@(test)
test_human_hps :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	human_hps(&b, 800_000)
	testing.expect(t, strings.to_string(b) == "800.00 KH/s", "KH/s formatting")

	strings.builder_reset(&b)
	human_hps(&b, 8_410_000)
	testing.expect(t, strings.to_string(b) == "8.41 MH/s", "MH/s formatting")

	strings.builder_reset(&b)
	human_hps(&b, 3.2e9)
	testing.expect(t, strings.to_string(b) == "3.20 GH/s", "GH/s formatting")
}

@(test)
test_share_plain_accepted :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format_share(&b, Console{color = false}, 12, 4, 14, 1, true, 0.61, "3f9a")
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "✔ accepted"), "shows accepted")
	testing.expect(t, strings.contains(out, "3f9a"), "shows job id")
	testing.expect(t, !strings.contains(out, "\x1b["), "no ANSI when color off")
}

@(test)
test_share_plain_rejected :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format_share(&b, Console{color = false}, 12, 5, 19, 2, false, 0, "3f9a", "low difficulty")
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "✘ rejected"), "shows rejected")
	testing.expect(t, strings.contains(out, "low difficulty"), "shows the reason verbatim")
}

@(test)
test_share_colored :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format_share(&b, Console{color = true}, 12, 4, 14, 1, true, 0.61, "3f9a")
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "\x1b[32m"), "green code present")
	testing.expect(t, strings.contains(out, "\x1b[0m"), "reset present")
}

// The safety block: a capped rate below network reads OK/green; the uncapped
// estimate above network reads danger and names the opt-in flag.
@(test)
test_safety_block_governed :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format_safety_block(&b, Console{color = false}, 800_000, 0.56, 500_000, 41e6)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "0.62× network"), "cap ratio shown")
	testing.expect(t, strings.contains(out, "OK, governed"), "capped-below-network reads OK")
	testing.expect(t, strings.contains(out, "needs --i-know-what-im-doing"), "uncapped estimate flags danger")
}

// A cap ABOVE network must read danger, in bold red, and name the flag.
@(test)
test_safety_block_dangerous_cap :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	format_safety_block(&b, Console{color = true}, 800_000, 0.56, 2_000_000, 41e6)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "2.50× network"), "over-cap ratio shown")
	testing.expect(t, strings.contains(out, "refuses without --i-know-what-im-doing"), "over-network cap refuses")
	testing.expect(t, strings.contains(out, "\x1b[1;31m"), "danger is bold red")
}
