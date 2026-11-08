#+dialect hela

// ABI pin. The layouts of the types below are recorded in `golden.hash`, and
// `tests/hela/run.sh` regenerates the manifest and diffs the hashes. That catches an accidental
// ABI change (`~`), and an accidental addition or removal (`+`/`-`), at review time instead of in
// production.
//
// An intentional layout change is a two-line commit: this file, plus regenerating the golden file
// with `HELA_UPDATE_GOLDEN=1 ./tests/hela/run.sh`.
package abi

import "base:intrinsics"

CACHE_LINE :: 64

// Shared-nothing ring header: one thread owns `head`, another owns `tail`, and the two cursors
// are kept on separate cache lines so they never ping-pong.
Ring_Header :: struct #explicit #align(CACHE_LINE) {
	head:     u64,
	_:        [56]u8,
	tail:     u64,
	capacity: u64,
	_:        [48]u8,
}

// Two cursors, one per line: the same bytes `Ring_Header` spells out with padding arrays, written
// as a declaration instead. Both spellings have to produce the same layout, which is why the pair
// lives in the pinned package.
Cursor :: struct #split(CACHE_LINE) {
	head: u64,
	tail: u64,
}

// A cache-resident slot. `seq` tells an empty slot from a full one without a shared counter.
Slot :: struct {
	seq:  u64,
	data: [56]u8,
}

// Ordinary Odin layout: the compiler inserts padding, and the manifest says exactly where.
Mixed :: struct {
	tag:   u8,
	value: u64,
	count: u16,
}

// No padding at all: what a wire or file format wants.
Wire :: struct #packed {
	kind:   u16,
	length: u32,
	flags:  u8,
}

Flags :: bit_field u16 {
	present: bool | 1,
	dirty:   bool | 1,
	epoch:   u8   | 6,
}

Vec3 :: struct {
	x, y, z: f32,
}

// 64 `Vec3`-shaped elements transposed into three parallel arrays: the SoA container the checker
// synthesises.
Particles :: #soa[64]Vec3
// The same shape as a slice: 32 bytes of header, the arrays live elsewhere.
Particle_View :: #soa[]Vec3

Vec4 :: #simd[4]f32
Mat4 :: matrix[4, 4]f32
Chunk :: [16]u8

Msg :: union { u32, u64 }

Kind :: enum u8 {
	Idle,
	Busy,
	Closed,
}

// No cache-line assertions here on purpose: this package is also the manifest source for
// `-layout-cache-line:128`, and anything that counts lines would make that build fail.
// `tests/hela/layout` owns the cache-line assertions.
#assert(size_of(Ring_Header) == 128)
#assert(intrinsics.layout_padding_of(Ring_Header) == 0)
#assert(offset_of_by_string(Ring_Header, "tail") == 64)

#assert(size_of(Slot) == 64)
#assert(size_of(Wire) == 7)
#assert(intrinsics.layout_padding_of(Wire) == 0)

#assert(size_of(Cursor) == 128)
#assert(offset_of_by_string(Cursor, "tail") == 64)
#assert(intrinsics.layout_padding_of(Cursor) == 112)

// 7 bytes of interior padding before `value`, 6 bytes of tail padding after `count`.
#assert(intrinsics.layout_padding_of(Mixed) == 13)
#assert(intrinsics.layout_tail_padding_of(Mixed) == 6)
#assert(offset_of_by_string(Mixed, "value") == 8)

#assert(size_of(Particles) == 64*12)
#assert(size_of(Vec4) == 16)
#assert(size_of(Mat4) == 64)

main :: proc() {}
