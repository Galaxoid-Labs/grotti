package main

// grotti.conf — a simple INI-style config file read from the directory containing the
// binary. Precedence: built-in defaults < grotti.conf < command-line flags. Keys
// match the flag names (pool, user, backend, threads, cap, color). Lines starting
// with '#' or ';' are comments; '[section]' headers are ignored.

import "core:os"
import "core:strconv"
import "core:strings"

// load_conf applies grotti.conf (if present, next to the executable) onto opts.
// Returns the path it looked at and whether a file was actually loaded.
load_conf :: proc(opts: ^Options) -> (path: string, loaded: bool) {
	dir, derr := os.get_executable_directory(context.temp_allocator)
	if derr != nil {
		return "", false
	}
	path = strings.concatenate({dir, "/grotti.conf"}, context.allocator)

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return path, false // no config file — that's fine
	}

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strings.trim_space(line)
		if len(s) == 0 || s[0] == '#' || s[0] == ';' || s[0] == '[' {
			continue
		}
		eq := strings.index_byte(s, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(s[:eq])
		val := strings.trim_space(s[eq + 1:])
		// clone: `data` lives in the temp allocator, but opts strings must outlive it.
		switch key {
		case "pool":
			opts.pool = strings.clone(val)
		case "user":
			opts.user = strings.clone(val)
		case "backend":
			opts.backend = strings.clone(val)
		case "color":
			opts.color = strings.clone(val)
		case "threads":
			if n, ok := strconv.parse_int(val); ok {
				opts.threads = n
			}
		case "cap":
			if f, ok := strconv.parse_f64(val); ok {
				opts.cap = f
			}
		}
	}
	return path, true
}

// normalize_pool strips a stratum URL scheme so both "host:port" and
// "stratum+tcp://host:port" are accepted for the endpoint.
normalize_pool :: proc(s: string) -> string {
	r := s
	for scheme in ([]string{"stratum+tcp://", "stratum+ssl://", "stratum://", "tcp://"}) {
		if strings.has_prefix(r, scheme) {
			r = r[len(scheme):]
			break
		}
	}
	return strings.trim_suffix(r, "/")
}
