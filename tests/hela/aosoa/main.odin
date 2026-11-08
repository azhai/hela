#+dialect hela

// `#aosoa[W][N]T` — array of structures of arrays, spelled from the logical side.
//
//   struct of arrays over the whole array:  x[0..N) y[0..N) z[0..N)        (one pass per field)
//   array of structs:                       xyz xyz xyz ...                (one pass, one cache line per element)
//   `#aosoa[8][N]`:                         8 x's, 8 y's, 8 z's, then the next 8 elements
//
// It is the layout that makes "walk field `x` over all elements" a contiguous scan while keeping a
// block small enough to stay in cache for the other fields. Written as `[N/W]#soa[W]T` it is already
// available in Odin; `#aosoa` states the element count instead of the block count, checks that they
// divide, and records the intent in `-emit-layout`.
package aosoa

import "base:intrinsics"
import "core:fmt"

WIDTH :: 8

Vec3 :: struct {
	x, y, z: f32,
}

// 1024 elements, 128 blocks of 8. One block is 8*3*4 = 96 bytes.
Particles :: #aosoa[WIDTH][1024]Vec3

// The same bytes, spelled with the block count: this is what `#aosoa` desugars to.
Blocks :: [1024/WIDTH]#soa[WIDTH]Vec3

#assert(size_of(Particles) == 1024 * size_of(Vec3))
#assert(size_of(Particles) == size_of(Blocks))
#assert(align_of(Particles) == align_of(Blocks))

// The block is the unit: `x` of the 8 elements in a block is contiguous, and the next block starts
// 96 bytes later.
#assert(intrinsics.layout_cache_lines_of(Particles) == 1024*12/64)

// One field of one block is 8*4 = 32 bytes, so `x`, `y`, `z` of a block fit in two cache lines.
#assert(size_of([WIDTH]f32) == 32)

Aosoa_Particles :: #aosoa[16][64]Vec3
#assert(size_of(Aosoa_Particles) == 64 * size_of(Vec3))
// A wider block is the same total bytes and a different access shape: the type says so.
#assert(size_of(Aosoa_Particles) == size_of(Particles) / 16)

main :: proc() {
	assert(size_of(Particles) == 12288)

	ps: Particles
	base := uintptr(&ps[0].x[0])

	// Field stride inside a block: `x[0..8)` then `y[0..8)` then `z[0..8)`.
	assert(uintptr(&ps[0].x[0]) - base == 0)
	assert(uintptr(&ps[0].y[0]) - base == 32)
	assert(uintptr(&ps[0].z[0]) - base == 64)

	// Block stride: 96 bytes.
	assert(uintptr(&ps[1].x[0]) - base == 96)
	assert(uintptr(&ps[2].x[0]) - base == 192)

	// Element stride *inside* a block: 4 bytes. This is the whole reason for the layout: eight
	// consecutive elements of one field are 32 bytes, i.e. within one cache line half.
	assert(uintptr(&ps[0].x[1]) - uintptr(&ps[0].x[0]) == 4)

	// Round-trip: every element of every field lands somewhere distinct.
	for b in 0 ..< 1024/WIDTH {
		for lane in 0 ..< WIDTH {
			ps[b].x[lane] = f32( b*WIDTH + lane)
			ps[b].y[lane] = f32( b*WIDTH + lane) + 0.5
			ps[b].z[lane] = f32( b*WIDTH + lane) + 0.25
		}
	}
	for b in 0 ..< 1024/WIDTH {
		for lane in 0 ..< WIDTH {
			i := b*WIDTH + lane
			if ps[b].x[lane] != f32(i) || ps[b].y[lane] != f32(i)+0.5 || ps[b].z[lane] != f32(i)+0.25 {
				fmt.panicf("element %d did not round-trip", i)
			}
		}
	}

	// Walking one field is a contiguous scan: sum of x over a block is the sum of 8 adjacent floats.
	want := f32(0)
	for lane in 0 ..< WIDTH {
		want += ps[3].x[lane]
	}
	got := f32(0)
	ptr := cast([^]f32)&ps[3].x[0]
	for lane in 0 ..< WIDTH {
		got += ptr[lane]
	}
	if got != want {
		fmt.panicf("walking x over one block is not contiguous: %v vs %v", got, want)
	}

	fmt.println("aosoa tests: ok")
}
