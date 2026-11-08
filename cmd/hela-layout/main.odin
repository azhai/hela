#+dialect hela

// hela-layout: inspect and diff memory-layout manifests produced by
//
//     odin check <pkg> -emit-layout:json -emit-layout-file:layout.json
//
// Usage:
//     hela-layout <manifest.json>                 print every type
//     hela-layout <manifest.json> <Type>...       print selected types
//     hela-layout --diff <old.json> <new.json>    compare, exit 1 if anything changed
//     hela-layout --hashes <manifest.json>        one `pkg::name<TAB>hash` line per type
//     hela-layout --waste <manifest.json> [N]     rank types by padding, worst first (N = limit)
//     hela-layout --contract <manifest.json>      one owner + atomics per cache line
//     hela-layout --stable <a.json> <b.json>...   compare layout hashes across targets
//     hela-layout --bits <manifest.json>          bit map of every bit_field type + mask check
//
// Any of the report modes accepts `--cache-line:N` (or `--cache-line N`): the manifest's offsets are
// facts, the line size is a lens, so the same manifest can be re-read at 128 B without recompiling.
//
// `--hashes` is the golden-file format: it is stable across machines and across manifest schema
// changes, so a committed copy plus `diff` is a usable ABI gate in CI. `--stable` needs manifest
// v6 (which carries `target`), because comparing a host manifest to itself proves nothing.
// `--bits` needs v7, which exports the per-segment `bit_mask`.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "core:hela/layout"

// `--stable` compares a handful of cross-checked manifests; a fixed bound keeps the CLI
// allocation-free and makes a malformed invocation fail before it reads anything.
MAX_MANIFESTS :: 16

usage :: proc() {
	fmt.eprintln("usage:")
	fmt.eprintln("  hela-layout <manifest.json>")
	fmt.eprintln("  hela-layout <manifest.json> <Type>...")
	fmt.eprintln("  hela-layout --diff <old.json> <new.json>")
	fmt.eprintln("  hela-layout --hashes <manifest.json>")
	fmt.eprintln("  hela-layout --waste <manifest.json> [limit]")
	fmt.eprintln("  hela-layout --contract <manifest.json>")
	fmt.eprintln("  hela-layout --stable <a.json> <b.json>...")
	fmt.eprintln("  hela-layout --bits <manifest.json>")
	fmt.eprintln("  any of the above also accepts --cache-line:N (re-read at a different line size)")
}

// `--cache-line` is accepted anywhere in the argv, in both spellings, because it qualifies every
// mode rather than one of them. Returns the remaining arguments in order.
CACHE_LINE_FLAG :: "--cache-line"

split_cache_line_flag :: proc(args: []string) -> (rest: [dynamic]string, bytes: int) {
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == CACHE_LINE_FLAG {
			if i + 1 < len(args) {
				n, ok := strconv.parse_int(args[i + 1])
				if !ok || n <= 0 {
					fmt.eprintln("--cache-line needs a positive integer, got:", args[i + 1])
					os.exit(2)
				}
				bytes = n
				i += 1
			}
			continue
		}
		if len(a) > len(CACHE_LINE_FLAG) && a[:len(CACHE_LINE_FLAG)] == CACHE_LINE_FLAG && a[len(CACHE_LINE_FLAG)] == ':' {
			n, ok := strconv.parse_int(a[len(CACHE_LINE_FLAG) + 1:])
			if !ok || n <= 0 {
				fmt.eprintln("--cache-line needs a positive integer, got:", a)
				os.exit(2)
			}
			bytes = n
			continue
		}
		append(&rest, a)
	}
	return
}

// load parses a manifest and, when `--cache-line` was given, re-derives its line occupancy at that
// size. One place, because there are six call sites and every one of them wants the same thing.
load :: proc(path: string, cache_line: int) -> (m: layout.Manifest, ok: bool) {
	m, ok = layout.parse_file(path)
	if ok && cache_line > 0 {
		layout.set_cache_line(&m, cache_line, .Overridden)
	}
	return
}

main :: proc() {
	// argv[0] is the program name; the flag may appear anywhere after it.
	argv, cache_line := split_cache_line_flag(os.args[1:])
	defer delete(argv)
	positional: [dynamic]string
	append(&positional, os.args[0])
	defer delete(positional)
	append(&positional, ..argv[:])
	args := positional[:]
	if len(args) < 2 {
		usage()
		os.exit(2)
	}

	if args[1] == "--hashes" {
		if len(args) != 3 {
			usage()
			os.exit(2)
		}
		manifest, ok := load(args[2], cache_line)
		if !ok {
			fmt.eprintln("cannot read manifest:", args[2])
			os.exit(2)
		}
		for &t in manifest.types {
			fmt.printf("%s::%s\t%s\n", t.pkg, t.name, t.layout_hash)
		}
		return
	}

	if args[1] == "--stable" {
		count := len(args) - 2
		if count < 2 || count > MAX_MANIFESTS {
			usage()
			os.exit(2)
		}
		manifests: [MAX_MANIFESTS]layout.Manifest
		for i in 0..<count {
			m, ok := load(args[i + 2], cache_line)
			if !ok {
				fmt.eprintln("cannot read manifest:", args[i + 2])
				os.exit(2)
			}
			if m.version < 6 || m.target == "" {
				fmt.eprintln("--stable needs a v6 manifest with a target:", args[i + 2])
				os.exit(2)
			}
			manifests[i] = m
		}
		b: strings.Builder
		strings.builder_init(&b)
		layout.stable_report(&b, manifests[:count])
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		return
	}

	if args[1] == "--bits" {
		if len(args) != 3 {
			usage()
			os.exit(2)
		}
		manifest, ok := load(args[2], cache_line)
		if !ok {
			fmt.eprintln("cannot read manifest:", args[2])
			os.exit(2)
		}
		if manifest.version < 7 {
			fmt.eprintln("--bits needs a v7 manifest with bit_mask:", args[2])
			os.exit(2)
		}
		b: strings.Builder
		strings.builder_init(&b)
		layout.bits_report(&b, &manifest)
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		return
	}

	if args[1] == "--contract" {
		if len(args) != 3 {
			usage()
			os.exit(2)
		}
		manifest, ok := load(args[2], cache_line)
		if !ok {
			fmt.eprintln("cannot read manifest:", args[2])
			os.exit(2)
		}
		b: strings.Builder
		strings.builder_init(&b)
		layout.contract_report(&b, &manifest)
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		return
	}

	if args[1] == "--waste" {
		if len(args) < 3 || len(args) > 4 {
			usage()
			os.exit(2)
		}
		manifest, ok := load(args[2], cache_line)
		if !ok {
			fmt.eprintln("cannot read manifest:", args[2])
			os.exit(2)
		}
		limit := 0
		if len(args) == 4 {
			n, conv_ok := strconv.parse_int(args[3])
			if !conv_ok || n < 0 {
				fmt.eprintln("limit must be a non-negative integer:", args[3])
				os.exit(2)
			}
			limit = n
		}
		b: strings.Builder
		strings.builder_init(&b)
		layout.waste_report(&b, &manifest, limit)
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		return
	}

	if args[1] == "--diff" {
		if len(args) != 4 {
			usage()
			os.exit(2)
		}
		old, old_ok := load(args[2], cache_line)
		if !old_ok {
			fmt.eprintln("cannot read manifest:", args[2])
			os.exit(2)
		}
		new, new_ok := load(args[3], cache_line)
		if !new_ok {
			fmt.eprintln("cannot read manifest:", args[3])
			os.exit(2)
		}
		b: strings.Builder
		strings.builder_init(&b)

		same := layout.diff_report(&old, &new, &b)
		if same {
			fmt.println("layout: identical")
			strings.builder_destroy(&b)
			os.exit(0)
		}
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		os.exit(1)
	}

	manifest, ok := load(args[1], cache_line)
	if !ok {
		fmt.eprintln("cannot read manifest:", args[1])
		os.exit(2)
	}

	if len(args) == 2 {
		b: strings.Builder
		strings.builder_init(&b)
		// The byte map below is cut at cache lines, so say which line cut it. Selected-type output
		// (`hela-layout m.json Cursor`) stays bare so it remains diffable against a golden text;
		// the banner there would be one line of noise per invocation.
		fmt.sbprintf(&b, "%s\n\n", layout.line_banner(layout.line_of(&manifest)))
		for &t in manifest.types {
			layout.render_type(&b, &t, manifest.cache_line)
			fmt.sbprintf(&b, "\n")
		}
		fmt.print(strings.to_string(b))
		strings.builder_destroy(&b)
		return
	}

	failed := false
	for name in args[2:] {
		t, found := layout.find(&manifest, name)
		if !found {
			fmt.eprintln("no such type:", name)
			failed = true
			continue
		}
		b: strings.Builder
		strings.builder_init(&b)
		layout.render_type(&b, t, manifest.cache_line)
		fmt.print(strings.to_string(b))
		fmt.println()
		strings.builder_destroy(&b)
	}
	if failed {
		os.exit(1)
	}
}
