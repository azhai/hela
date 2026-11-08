#+dialect hela

// Cache-line occupancy is the one part of a manifest that is not a fact about the program.
//
// Offsets, sizes and alignments are decided by the compiler and cannot change without changing the
// bytes. `cache_line` is different: it is the size the compiler was *told* to measure against
// (`-layout-cache-line`), or 64 when nobody said anything. On an Apple Silicon machine the line is
// 128 bytes, so a type that is "one line" at 64 is half a line there — and a `#share` contract that
// keeps two writers apart at 64 keeps them on the same line at 128.
//
// Two consequences, and this file is both of them:
//
//   * the manifest must say whether its number was chosen or defaulted (`cache_line_explicit`),
//     so a report can call a default a default instead of presenting it as a decision;
//   * the number is a *reading* parameter, not a build one. `hela-layout --cache-line 128` rewrites
//     the derived fields from the offsets — no recompilation, no second manifest — because the
//     offsets are the facts and the line size is a lens.
package layout

import "core:fmt"
import "core:strings"

// Where the line size a report is using came from.
Line_Source :: enum {
	Declared,   // `-layout-cache-line` said so at check time
	Default,    // the compiler's fallback; nobody decided anything
	Overridden, // the reader passed `--cache-line`; the manifest assumed something else
}

// Line is the line size in effect plus its provenance.
Line :: struct {
	bytes:    int,
	source:   Line_Source,
	compiled: int, // the manifest's own number; differs from `bytes` only when overridden
}

// line_of describes the line size `m` should be read at.
line_of :: proc(m: ^Manifest) -> Line {
	compiled := m.cache_line
	if m.cache_line_compiled > 0 {
		compiled = m.cache_line_compiled
	}
	if compiled > 0 && compiled != m.cache_line {
		return Line{bytes = m.cache_line, source = .Overridden, compiled = compiled}
	}
	return Line {
		bytes = m.cache_line,
		source = m.cache_line_explicit ? .Declared : .Default,
		compiled = compiled,
	}
}

// line_banner is the sentence every report that does line arithmetic starts with. It is a sentence
// rather than a number because "64" on its own reads like a measurement, and it is not one.
line_banner :: proc(l: Line) -> string {
	switch l.source {
	case .Declared:
		return fmt.tprintf("cache line %d B (from -layout-cache-line)", l.bytes)
	case .Default:
		return fmt.tprintf("cache line %d B (compiler default, not a decision: pass -layout-cache-line:N"+
			" if this target fetches a different size)", l.bytes)
	case .Overridden:
		return fmt.tprintf("cache line %d B (--cache-line; the manifest was built for %d B)",
			l.bytes, l.compiled)
	}
	return fmt.tprintf("cache line %d B", l.bytes)
}

// line_source_name is the short form used in column output (`--stable`'s header lines).
line_source_name :: proc(s: Line_Source) -> string {
	switch s {
	case .Declared:
		return "declared"
	case .Default:
		return "default"
	case .Overridden:
		return "overridden"
	}
	return "unknown"
}

// set_cache_line rewrites every line-derived field for `bytes`. The derivations are the compiler's
// own (`layout_field_cache_line` in layout_hash.cpp, `cache_lines` in layout_writer.cpp), repeated
// here on purpose: the reader must be able to re-derive them, or the manifest's numbers would be
// the only answer and the line size could never be questioned.
set_cache_line :: proc(m: ^Manifest, bytes: int, source: Line_Source) {
	if bytes <= 0 {
		return
	}
	if source == .Overridden && m.cache_line_compiled == 0 {
		m.cache_line_compiled = m.cache_line
	}
	m.cache_line = bytes
	if source == .Overridden {
		m.cache_line_explicit = m.cache_line_compiled > 0 && m.cache_line_compiled != bytes
	}
	for &t in m.types {
		t.cache_lines = (t.size + bytes - 1) / bytes
		for &f in t.fields {
			field_set_cache_line(&f, bytes)
		}
		for &f in t.variants {
			field_set_cache_line(&f, bytes)
		}
	}
}

@(private)
field_set_cache_line :: proc(f: ^Field_Layout, bytes: int) {
	f.cache_line = f.offset / bytes
	// Same definition as the compiler's: a field spans a line when it starts inside one and ends
	// after its end. A field that starts exactly at a boundary does not span, it starts a new line.
	f.spans_cache_line = (f.offset % bytes) + f.size > bytes
}

// straddle_summary appends one line about types that carry a `#share` field and whose size is not a
// whole number of cache lines. This is the M25 invariant (`[N]T` elements of a writer-bearing type
// would share a line with their neighbours) evaluated at the line size in effect — so it can be
// asked of a manifest that was built for another line size, which is exactly when it is
// interesting. Returns how many such types there are.
straddle_summary :: proc(b: ^strings.Builder, m: ^Manifest) -> int {
	count := 0
	for &t in m.types {
		annotated := false
		for &f in t.fields {
			if f.share != "" {
				annotated = true
				break
			}
		}
		if !annotated || t.size == 0 || t.size % m.cache_line == 0 {
			continue
		}
		count += 1
		if count == 1 {
			fmt.sbprintf(b, "\nshared type(s) not a whole number of %d B lines"+
				" (element i would share a line with i+1):", m.cache_line)
		}
		if count <= 8 {
			fmt.sbprintf(b, " %s::%s(%d B)", t.pkg, t.name, t.size)
		} else if count == 9 {
			fmt.sbprintf(b, " ...")
		}
	}
	if count > 0 {
		fmt.sbprintf(b, "\n")
	}
	return count
}
