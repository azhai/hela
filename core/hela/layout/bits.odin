#+dialect hela

// Bit-level view of a layout manifest.
//
// Byte offsets were only half of the wire format: a `bit_field` header also decides which *bits*
// belong to `kind`, which to `flags`, and which are unused. Manifest v7 exports each segment's
// mask (`bit_mask`), derived by the compiler from `bit_offset`/`bit_size` — the very same helper
// the `layout_bit_mask_of` / `layout_bit_encode_of` intrinsics use. This report renders that as a
// bit map and re-derives every mask from the segment bounds, so a hand-edited or stale manifest
// cannot quietly disagree with the compiler.
package layout

import "core:fmt"
import "core:strconv"
import "core:strings"

// segment_mask is the reader-side counterpart of the compiler's bit_field_mask(). Keeping them
// as two independent computations is deliberate: if they agree, the exported `bit_mask` really is
// derived from `bit_offset`/`bit_size` rather than merely plausible-looking.
segment_mask :: proc(offset, width: int) -> u64 {
	if width <= 0 || offset < 0 || offset + width > 64 {
		return 0
	}
	m: u64 = 0
	if width >= 64 {
		m = ~u64(0)
	} else {
		m = (u64(1) << uint(width)) - 1
	}
	return m << uint(offset)
}

word_mask :: proc(bit_count: int) -> u64 {
	if bit_count <= 0 {
		return 0
	}
	if bit_count >= 64 {
		return ~u64(0)
	}
	return (u64(1) << uint(bit_count)) - 1
}

bits_set :: proc(value: u64) -> int {
	x := value
	n := 0
	for x != 0 {
		n += int(x & 1)
		x >>= 1
	}
	return n
}

// bits_report prints one block per `bit_field` type, in manifest order (already stable). It is
// deterministic and allocation-free beyond the builder.
bits_report :: proc(b: ^strings.Builder, m: ^Manifest) {
	fmt.sbprintf(b, "bit layout (manifest v%d)\n\n", m.version)

	count := 0
	mismatches := 0
	for &t in m.types {
		if t.kind != "bit_field" {
			continue
		}
		count += 1
		fmt.sbprintf(b, "%s::%s  backing=%s  width=%d bit(s)  hash=%s\n",
			t.pkg, t.name, t.backing, t.size * 8, t.layout_hash)

		covered: u64 = 0
		for &f in members(&t) {
			if f.bit_size <= 0 || f.bit_offset < 0 {
				continue
			}
			expected := segment_mask(f.bit_offset, f.bit_size)
			got, parsed := strconv.parse_u64_maybe_prefixed(f.bit_mask)
			state := "ok"
			if !parsed || got != expected {
				state = "MISMATCH"
				mismatches += 1
			}
			fmt.sbprintf(b, "  bits %02d..%02d  %s  width=%d  mask=%s  %s\n",
				f.bit_offset, f.bit_offset + f.bit_size - 1, f.name,
				f.bit_size, f.bit_mask, state)
			covered |= expected
		}

		unused := word_mask(t.size * 8) & ~covered
		if unused != 0 {
			fmt.sbprintf(b, "  unused bits                  mask=0x%x\n", unused)
		}
		fmt.sbprintf(b, "  segments=%d  covered=%d bit(s)  unused=%d bit(s)\n\n",
			len(members(&t)), bits_set(covered), bits_set(unused))
	}

	if count == 0 {
		fmt.sbprintf(b, "  no bit_field types in this manifest\n\n")
	}
	fmt.sbprintf(b, "bit_field types: %d  mask mismatches: %d\n", count, mismatches)
}
