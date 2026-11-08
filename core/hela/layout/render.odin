#+dialect hela

// Renders a layout manifest as a byte map: one block per 64-byte cache line, listing what lives
// where, including the padding the compiler inserted.
package layout

import "core:fmt"
import "core:strings"

// render_type appends a human-readable description of one type. `cache_line` should be the
// `cache_line` value of the manifest the type came from.
render_type :: proc(b: ^strings.Builder, t: ^Type_Layout, cache_line := 64) {
	fmt.sbprintf(b, "%s\t(%s, %s)\n", t.name, t.kind, t.pkg)
	fmt.sbprintf(b, "  size %d B\talign %d B\tcache lines %d\tpadding %d B (tail %d)\thash %s\n",
		t.size, t.align, t.cache_lines, t.padding, t.tail_padding, t.layout_hash)
	// Which tag produced this layout. The difference matters for the byte map below: padding that
	// `#split` generated is accounted for by a formula, padding with no tag is padding nobody
	// asked for.
	if t.split > 0 {
		fmt.sbprintf(b, "  declared\t#split(%d)\n", t.split)
	} else if t.explicit {
		fmt.sbprintf(b, "  declared\t#explicit\n")
	}

	fields := members(t)

	// Types with no members have no byte map to draw: an array has elements, not fields, and
	// printing its whole size as "tail padding" (which is what the loop below would do) is worse
	// than printing nothing.
	if len(fields) == 0 {
		switch t.kind {
		case "array":
			fmt.sbprintf(b, "  elem\t%s\t[%d]\tstride %d B\n", t.elem, t.count, t.stride)
		case "matrix":
			fmt.sbprintf(b, "  matrix\t%d x %d\tstride %d B\trow major %v\n", t.rows, t.columns, t.stride, t.row_major)
		case "enum", "bit_set":
			fmt.sbprintf(b, "  underlying\t%s\n", t.underlying)
		case "bit_field":
			fmt.sbprintf(b, "  backing\t%s\n", t.backing)
		}
		return
	}

	line   := -1
	cursor := 0

	pad_label  := "<padding>"
	tail_label := "<tail padding>"
	if t.split > 0 {
		pad_label  = "<stride>"
		tail_label = "<stride tail>"
	}

	for f in fields {
		if f.offset > cursor {
			line = render_entry(b, pad_label, cursor, f.offset-cursor, "", line, cache_line)
		}
		line = render_entry(b, f.name, f.offset, f.size, f.type, line, cache_line, f.declared_align, f.declared_offset, f.atomic, f.share)
		if f.offset+f.size > cursor {
			cursor = f.offset+f.size
		}
	}
	if t.size > cursor {
		render_entry(b, tail_label, cursor, t.size-cursor, "", line, cache_line)
	}
}

// render_entry prints one row, opening a new cache-line block when needed, and returns the
// cache line the row landed in. `declared_align` is a field-level `#align(N)` and
// `declared_offset` a field-level `#offset(N)`: the row says so, because "this field sits at 64"
// and "this field is required to sit at 64" are different promises. `atomic`/`share` are the
// concurrency contract: they do not move a byte, but they do change who may write one.
render_entry :: proc(b: ^strings.Builder, name: string, offset, size: int, type: string, line_in: int, cache_line_in: int, declared_align := 0, declared_offset := -1, atomic := false, share := "") -> int {
	cache_line := cache_line_in
	if cache_line <= 0 {
		cache_line = 64
	}
	line := line_in
	entry_line := offset / cache_line
	if entry_line != line {
		line = entry_line
		fmt.sbprintf(b, "  line %d\t[%d..%d]\n", line, line*cache_line, (line+1)*cache_line-1)
	}
	if type == "" {
		fmt.sbprintf(b, "    %s\t@%d\t%d B", name, offset, size)
	} else if declared_offset >= 0 {
		fmt.sbprintf(b, "    %s\t@%d\t%d B\t%s\t#offset(%d)", name, offset, size, type, declared_offset)
	} else if declared_align > 0 {
		fmt.sbprintf(b, "    %s\t@%d\t%d B\t%s\t#align(%d)", name, offset, size, type, declared_align)
	} else {
		fmt.sbprintf(b, "    %s\t@%d\t%d B\t%s", name, offset, size, type)
	}
	if atomic {
		fmt.sbprintf(b, "\t#atomic")
	}
	if share != "" {
		fmt.sbprintf(b, "\t#share(%s)", share)
	}
	fmt.sbprintf(b, "\n")
	return line
}

// render_all appends every type, in manifest order (the compiler sorts by package, then name).
render_all :: proc(m: ^Manifest) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	for &t in m.types {
		render_type(&b, &t)
		fmt.sbprintf(&b, "\n")
	}
	return strings.to_string(b)
}
