#+dialect hela

// `#align(N)` on a field pins that field's offset to an N-byte boundary, and makes the struct
// N-byte aligned so that an *array* of the struct keeps the promise. It is the per-field form of
// `#min_field_align`, i.e. the tool you need when only some fields must not be shared:
//
//     Counter :: struct {
//         #align(64) pushes: u64,
//         #align(64) pops:   u64,
//         hits:  u64,
//         bytes: u64,
//     }
//
// Two writers, two cache lines. `hits`/`bytes` still share the second line, which is correct if one
// thread writes both.
package field_align

import "base:intrinsics"
import "core:fmt"

CACHE_LINE :: 64

// The same bytes, written out by hand. Nothing about `Counter` depends on the compiler guessing
// better than this: it only depends on the compiler not inserting an offset nobody asked for.
Manual :: struct {
	pushes: u64,
	_:      [CACHE_LINE-8]u8,
	pops:   u64,
	hits:   u64,
	bytes:  u64,
	_:      [40]u8,
}

Counter :: struct {
	#align(CACHE_LINE) pushes: u64,
	#align(CACHE_LINE) pops:   u64,
	hits:  u64,
	bytes: u64,
}

#assert(size_of(Counter) == size_of(Manual))
#assert(offset_of_by_string(Counter, "pushes") == offset_of_by_string(Manual, "pushes"))
#assert(offset_of_by_string(Counter, "pops") == offset_of_by_string(Manual, "pops"))
#assert(offset_of_by_string(Counter, "hits") == offset_of_by_string(Manual, "hits"))
#assert(offset_of_by_string(Counter, "bytes") == offset_of_by_string(Manual, "bytes"))

// The struct itself is 64-byte aligned, otherwise `[2]Counter` would put the second `pushes` 128
// bytes after the first one only by luck.
#assert(align_of(Counter) == CACHE_LINE)
#assert(size_of(Counter) % CACHE_LINE == 0)

// 128 bytes, two cache lines; 96 of the bytes are padding, 40 of them at the end.
#assert(intrinsics.layout_cache_lines_of(Counter) == 2)
#assert(intrinsics.layout_padding_of(Counter) == 96)
#assert(intrinsics.layout_tail_padding_of(Counter) == 40)

// `#align` only ever raises: a small field pushed to 32 bytes leaves the rest packed.
Mixed :: struct {
	a: u8,
	#align(32) b: u8,
	c: u8,
}
#assert(offset_of_by_string(Mixed, "a") == 0)
#assert(offset_of_by_string(Mixed, "b") == 32)
#assert(offset_of_by_string(Mixed, "c") == 33)
#assert(align_of(Mixed) == 32)
#assert(size_of(Mixed) == 64)

// A polymorphic struct is re-checked at every instantiation, so the field alignment has to survive
// that: it is stored on the field entity, not on the (shared) struct type.
Aligned_Ring :: struct($T: typeid) {
	#align(CACHE_LINE) head:  u64,
	tail:  u64,
	#align(CACHE_LINE) slots: [8]T,
}

#assert(offset_of_by_string(Aligned_Ring(u32), "head") == 0)
#assert(offset_of_by_string(Aligned_Ring(u32), "tail") == 8)
#assert(offset_of_by_string(Aligned_Ring(u32), "slots") == CACHE_LINE)
#assert(align_of(Aligned_Ring(u32)) == CACHE_LINE)
// 64 + 8*4 = 96, rounded up to the 64-byte alignment the declaration asked for.
#assert(size_of(Aligned_Ring(u32)) == 128)
// Same declaration, different slot size: the alignment is the declaration's, the size is not.
#assert(offset_of_by_string(Aligned_Ring(u128), "slots") == CACHE_LINE)
#assert(size_of(Aligned_Ring(u128)) == 192)

main :: proc() {
	assert(align_of(Counter) == CACHE_LINE)
	assert(offset_of(Counter, pushes) == 0)
	assert(offset_of(Counter, pops) == CACHE_LINE)

	// The whole point: in an array, `pushes` of every element starts on a line boundary.
	cs: [4]Counter
	for &c, i in cs {
		addr := uintptr(&c.pushes)
		if addr % CACHE_LINE != 0 {
			fmt.panicf("cs[%d].pushes is not cache-line aligned: %x", i, addr)
		}
		if uintptr(&c.pops) % CACHE_LINE != 0 {
			fmt.panicf("cs[%d].pops is not cache-line aligned: %x", i, uintptr(&c.pops))
		}
	}
	if uintptr(&cs[0].pushes)/CACHE_LINE == uintptr(&cs[0].pops)/CACHE_LINE {
		fmt.panicf("pushes and pops ended up on the same cache line")
	}
	if uintptr(&cs[1].pushes) != uintptr(&cs[0].pushes)+2*CACHE_LINE {
		fmt.panicf("array stride is not two cache lines: %d", uintptr(&cs[1].pushes)-uintptr(&cs[0].pushes))
	}

	// Writes land where the declaration says they do.
	for &c, i in cs {
		c.pushes = u64(i) + 1
		c.pops   = u64(i) + 2
		c.hits   = u64(i) + 3
		c.bytes  = u64(i) + 4
	}
	for c, i in cs {
		if c.pushes != u64(i)+1 || c.pops != u64(i)+2 || c.hits != u64(i)+3 || c.bytes != u64(i)+4 {
			fmt.panicf("cs[%d] does not round-trip: %v", i, c)
		}
	}

	fmt.println("field align tests: ok")
}
