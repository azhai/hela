#+dialect hela

// Regression tests for Hela's layout guarantees. Everything here is checked at compile time by
// `#assert`, so `odin check` is the test.
package main

import "base:intrinsics"

CACHE_LINE :: 64

// Two single-writer words, each on its own cache line: no false sharing by construction, and no
// implicit padding either, because `#explicit` requires every byte to be named.
Ring_Header :: struct #explicit #align(CACHE_LINE) {
	head: u32,
	_:    [60]u8,
	tail: u32,
	_:    [60]u8,
}

// A normal Odin struct: the compiler inserts 3 bytes of padding before `b`, and the layout
// queries can see them.
Padded :: struct {
	a: u8,
	b: u32,
}

Packed :: struct #packed {
	a: u8,
	b: u32,
}

Bits :: bit_field u16 {
	x: u8  | 3,
	y: u16 | 5,
}

Vec :: #simd[4]f32

#assert(size_of(Ring_Header) == 128)
#assert(align_of(Ring_Header) == 64)
#assert(intrinsics.layout_padding_of(Ring_Header) == 0)
#assert(intrinsics.layout_tail_padding_of(Ring_Header) == 0)
#assert(intrinsics.layout_cache_lines_of(Ring_Header) == 2)
#assert(offset_of_by_string(Ring_Header, "tail") == 64)

#assert(intrinsics.layout_padding_of(Padded) == 3)
#assert(intrinsics.layout_tail_padding_of(Padded) == 0)
#assert(offset_of_by_string(Padded, "b") == 4)

#assert(size_of(Packed) == 5)
#assert(intrinsics.layout_padding_of(Packed) == 0)

#assert(intrinsics.type_field_bit_offset(Bits, "x") == 0)
#assert(intrinsics.type_field_bit_offset(Bits, "y") == 3)
#assert(size_of(Vec) == 16)

main :: proc() {}
