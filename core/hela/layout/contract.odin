#+dialect hela

// `--contract`: the concurrency half of the layout manifest.
//
// `-emit-layout` has always said *where every byte is*. Since v5 it also says *who writes it*
// (`#share(label)`) and *how* (`#atomic`). This file turns that into one line per cache line, so
// an agent (or a reviewer) can answer "which core owns this line?" without reading the source.
//
// A line with two different writers is a false-sharing bug the `#+analysis sharing` pass rejects
// at compile time; if one shows up here the manifest came from a build with the analysis off, so
// it is printed as CONFLICT rather than being silently tolerated.
package layout

import "core:fmt"
import "core:strings"

MAX_WRITERS :: 16

// contract_report appends a deterministic ownership map of every annotated type in `m`.
// Types with no `#share`/`#atomic` field are skipped: there is no contract to describe.
//
// The report opens with *which* cache line it is describing. `#share` is a promise about lines, and
// a manifest built for 64 B says nothing about a 128 B machine unless the reader says so — see
// `set_cache_line` / `--cache-line`.
contract_report :: proc(b: ^strings.Builder, m: ^Manifest) {
	cache_line := m.cache_line
	if cache_line <= 0 {
		cache_line = 64
	}
	fmt.sbprintf(b, "hela concurrency contract (%s)\n", line_banner(line_of(m)))

	conflicts := 0
	hints     := 0
	shown     := 0
	for &t in m.types {
		fields := members(&t)
		if len(fields) == 0 {
			continue
		}
		annotated := false
		for &f in fields {
			if f.share != "" || f.atomic {
				annotated = true
				break
			}
		}
		if !annotated {
			continue
		}
		shown += 1
		fmt.sbprintf(b, "\n%s::%s  (%d B, %d cache line(s))\n", t.pkg, t.name, t.size, t.cache_lines)

		max_line := 0
		for &f in fields {
			if f.cache_line > max_line {
				max_line = f.cache_line
			}
		}
		for line in 0..=max_line {
			owners: [MAX_WRITERS]string
			nowners := 0
			count   := 0
			for &f in fields {
				if f.cache_line != line {
					continue
				}
				count += 1
				if f.share != "" && !f.atomic {
					hints += 1
				}
				if f.share == "" {
					continue
				}
				known := false
				for i in 0..<nowners {
					if owners[i] == f.share {
						known = true
						break
					}
				}
				if !known && nowners < MAX_WRITERS {
					owners[nowners] = f.share
					nowners += 1
				}
			}
			if count == 0 {
				continue
			}
			owner := "-"
			if nowners > 1 {
				owner = "CONFLICT"
				conflicts += 1
			} else if nowners == 1 {
				owner = owners[0]
			}
			fmt.sbprintf(b, "  line %d [%d..%d] owner=%s :", line, line*cache_line, (line+1)*cache_line-1, owner)
			for &f in fields {
				if f.cache_line != line {
					continue
				}
				fmt.sbprintf(b, " %s@%d", f.name, f.offset)
				if f.atomic {
					fmt.sbprintf(b, "#atomic")
				}
				if f.share != "" {
					fmt.sbprintf(b, "#share(%s)", f.share)
				}
			}
			fmt.sbprintf(b, "\n")
		}
	}
	fmt.sbprintf(b, "\n%d type(s), %d line(s) with conflicting writers, %d shared field(s) without #atomic\n",
		shown, conflicts, hints)
	// The M25 invariant, at the line size in effect. Zero here means every writer-bearing type is a
	// whole number of lines, i.e. `[N]T` never puts two owners in one line.
	straddle_summary(b, m)
}
