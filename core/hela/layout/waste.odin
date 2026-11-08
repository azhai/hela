#+dialect hela

// "Which type wastes the most bytes?" is the question a layout pass exists to answer, and it is
// the one nobody can answer by reading the source: a struct looks fine field by field and is 60%
// padding in memory.
//
// This ranks every named type by padding, using the same `padding`/`tail_padding` the manifest
// already carries. No new compiler output is needed — the numbers were always there, just not
// sorted into an answer.
//
// Two numbers are deliberately kept apart:
//
//   * `padding` is everything no named field covers.
//   * `recoverable` is the part that reordering the fields could actually remove: interior padding
//     of a struct whose layout was not *declared*. `#split(64)` and `#explicit` padding is the
//     point of the declaration, so "fixing" it would break the program.
package layout

import "core:fmt"
import "core:slice"
import "core:strings"

// Waste is one row of the ranking: a type and how much of it is not payload.
Waste :: struct {
	pkg:          string,
	name:         string,
	kind:         string,
	size:         int,
	padding:      int, // interior + tail
	tail_padding: int, // the part after the last field
	// How the layout was declared, so the report does not present intentional padding as a bug.
	declared:     string, // "", "#split(64)", "#explicit"
}

// payload is the bytes a named field actually covers.
payload :: proc(w: Waste) -> int {
	return w.size - w.padding
}

// waste_percent is `padding / size`. Integer arithmetic on purpose: the report is compared in
// tests, and a stable integer beats a float that prints as 33.333333333333336.
waste_percent :: proc(w: Waste) -> int {
	if w.size == 0 {
		return 0
	}
	return (w.padding * 100) / w.size
}

// recoverable is the padding that reordering the fields could remove: interior padding of a type
// whose layout nobody declared. Trailing padding is the ABI rounding the size to the alignment, and
// declared padding is the declaration doing its job.
recoverable :: proc(w: Waste) -> int {
	if w.declared != "" {
		return 0
	}
	n := w.padding - w.tail_padding
	if n < 0 {
		n = 0
	}
	return n
}

// waste_rank sorts every type by padding, descending; ties are broken by package then name so the
// output is deterministic across runs. `min_size` skips tiny types, whose percentages are noise
// (a 3-byte struct with 1 byte of padding is not the problem you are looking for).
waste_rank :: proc(m: ^Manifest, min_size := 16) -> []Waste {
	rows := make([dynamic]Waste, 0, len(m.types))
	for &t in m.types {
		if t.size < min_size || t.padding <= 0 {
			continue
		}
		declared := ""
		if t.split > 0 {
			declared = fmt.tprintf("#split(%d)", t.split)
		} else if t.explicit {
			declared = "#explicit"
		}
		append(&rows, Waste{
			pkg          = t.pkg,
			name         = t.name,
			kind         = t.kind,
			size         = t.size,
			padding      = t.padding,
			tail_padding = t.tail_padding,
			declared     = declared,
		})
	}
	slice.sort_by(rows[:], proc(a, b: Waste) -> bool {
		if a.padding != b.padding {
			return a.padding > b.padding
		}
		if a.pkg != b.pkg {
			return a.pkg < b.pkg
		}
		return a.name < b.name
	})
	return rows[:]
}

// waste_report appends the ranking, `limit` rows of it (0 = all). The summary line is the part that
// matters for a whole repository: it turns "some structs are padded" into a number that can be
// printed in CI.
waste_report :: proc(b: ^strings.Builder, m: ^Manifest, limit := 0) {
	rows := waste_rank(m)
	defer delete(rows)

	// Padding itself does not depend on the cache line, but the declarations that *create* it do:
	// `#split(64)` and `#align(64)` are line-sized almost by definition, and `recoverable` is zero
	// for them. Saying which line the report is reading at keeps "this is deliberate" from looking
	// like a coincidence.
	fmt.sbprintf(b, "%s\n", line_banner(line_of(m)))

	total_size := 0
	total_padding := 0
	total_recoverable := 0
	for w in rows {
		total_size += w.size
		total_padding += w.padding
		total_recoverable += recoverable(w)
	}

	shown := len(rows)
	if limit > 0 && limit < shown {
		shown = limit
	}

	fmt.sbprintf(b, "%-34s %-8s %6s %8s %7s %7s  %s\n",
		"type", "kind", "size", "padding", "tail", "waste", "declared")
	for w in rows[:shown] {
		fmt.sbprintf(b, "%-34s %-8s %6d %8d %7d %6d%%  %s\n",
			fmt.tprintf("%s::%s", w.pkg, w.name), w.kind, w.size, w.padding, w.tail_padding,
			waste_percent(w), w.declared)
	}
	if shown < len(rows) {
		fmt.sbprintf(b, "... %d more\n", len(rows)-shown)
	}
	if total_size > 0 {
		fmt.sbprintf(b, "\n%d type(s), %d B total, %d B padding (%d%%), %d B recoverable by reordering\n",
			len(rows), total_size, total_padding,
			(total_padding*100)/total_size, total_recoverable)
	} else {
		fmt.sbprintf(b, "no type with padding on record\n")
	}
}
