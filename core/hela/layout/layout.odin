#+dialect hela

// Machine-readable memory-layout manifests produced by:
//
//     odin check <pkg> -emit-layout:json -emit-layout-file:layout.json
//
// The compiler is the single source of truth for layout; this package only reads what it wrote.
// It exists so that a program (or a person, or a model) can inspect bytes instead of guessing
// padding, alignment and cache-line occupancy from source text.
package layout

import "core:encoding/json"
import "core:os"

// Manifest mirrors the top-level object of the manifest.
Manifest :: struct {
	version:    int,
	generator:  string,
	// Which target this manifest was checked for. Metadata only: `layout_hash` describes bytes,
	// so the same hash under two targets means the bytes really are identical. `pointer_size`
	// lets a reader explain a drift without having to know Odin's target names.
	target:       string,
	pointer_size: int,
	cache_line:   int,
	// Manifest v8: true when `-layout-cache-line` chose `cache_line`, false when it is the
	// compiler's 64-byte fallback. The number alone cannot say which — and on a 128-byte-line
	// machine the difference decides whether `#share` separated anything at all.
	cache_line_explicit: bool,
	// Set by `set_cache_line` when the reader overrides the line size, so a report can print both
	// numbers ("built for 64, read at 128"). Zero means "never overridden".
	cache_line_compiled: int,
	types:        []Type_Layout,
}

// Type_Layout is one named type. Which of `fields` / `variants` / `elem` / `rows` / `underlying`
// are set depends on `kind`; every type has `size`, `align`, `padding` and `layout_hash`.
Type_Layout :: struct {
	name:         string,
	pkg:          string,
	file:         string,
	line:         int,
	kind:         string,
	size:         int,
	align:        int,
	packed:       bool,
	soa:          string,
	cache_lines:  int,
	padding:      int,
	tail_padding: int,
	// How the layout was declared. `explicit` is `#explicit` (every byte named), `split` is the
	// stride of `#split(N)` (0 when unused). Neither affects `layout_hash`: they describe the
	// source, not the bytes.
	explicit:     bool,
	split:        int,
	layout_hash:  string,

	fields:     []Field_Layout,
	variants:   []Field_Layout,
	elem:       string,
	count:      int,
	stride:     int,
	rows:       int,
	columns:    int,
	row_major:  bool,
	underlying: string,
	backing:    string,
}

// Field_Layout describes one field (or, for unions, one variant). `bit_offset` is -1 and
// `bit_size` is 0 for everything that is not a `bit_field` member.
Field_Layout :: struct {
	name:             string,
	type:             string,
	offset:           int,
	size:             int,
	align:            int, // the alignment the offset was computed with
	declared_align:   int, // the N of a field-level `#align(N)`, 0 when the field has none
	declared_offset:  int, // the N of a field-level `#offset(N)`, -1 when the field has none
	// Hela concurrency contract (manifest v5). Neither changes a byte and neither is part of
	// `layout_hash`; they say who writes the field and whether the access is atomic.
	atomic:           bool,
	share:            string, // empty when the field has no `#share(label)`
	cache_line:       int,
	spans_cache_line: bool,
	padding_before:   int,
	bit_offset:       int,
	bit_size:         int,
	// Manifest v7: the field's mask, already shifted into place in the backing word. Derived by
	// the compiler from `bit_offset`/`bit_size` (the same helper the `layout_bit_*` intrinsics
	// use), so a pattern table and the manifest cannot disagree. Empty for ordinary fields.
	bit_mask:         string,
}

// parse_file reads and decodes a manifest. Every string is cloned into `allocator`, so the input
// buffer is released before returning.
parse_file :: proc(path: string, allocator := context.allocator) -> (m: Manifest, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return {}, false
	}
	defer delete(data, allocator)

	if json.unmarshal(data, &m, json.DEFAULT_SPECIFICATION, allocator) != nil {
		return {}, false
	}
	return m, true
}

// find looks a type up by name, ignoring the package.
find :: proc(m: ^Manifest, name: string) -> (^Type_Layout, bool) {
	for &t in m.types {
		if t.name == name {
			return &t, true
		}
	}
	return nil, false
}

// find_in looks a type up by package and name.
find_in :: proc(m: ^Manifest, pkg, name: string) -> (^Type_Layout, bool) {
	for &t in m.types {
		if t.name == name && t.pkg == pkg {
			return &t, true
		}
	}
	return nil, false
}

// members returns whichever of `fields` / `variants` this type has.
members :: proc(t: ^Type_Layout) -> []Field_Layout {
	if len(t.fields) > 0 {
		return t.fields
	}
	return t.variants
}
