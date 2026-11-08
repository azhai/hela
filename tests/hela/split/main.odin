#+dialect hela

// `#split(N)` puts every field on its own N-byte boundary and ends the struct on one. It is the
// one-tag form of `#explicit` plus a hand-computed `_: [N-field_size]u8` after every field: same
// bytes, but nothing to recompute when a field is added, and the stride is stated instead of
// inferred from arithmetic.
//
// The point of this file is that the two spellings can be compared at compile time. If they ever
// disagree, one of them describes a layout the compiler does not produce.
package split

import "base:intrinsics"
import "core:fmt"

CACHE_LINE :: 64

// By hand.
Manual :: struct #explicit #align(CACHE_LINE) {
	head: u64,
	_:    [CACHE_LINE-8]u8,
	tail: u64,
	_:    [CACHE_LINE-8]u8,
	flag: u8,
	_:    [CACHE_LINE-1]u8,
}

// By declaration.
Split :: struct #split(CACHE_LINE) {
	head: u64,
	tail: u64,
	flag: u8,
}

#assert(size_of(Split) == size_of(Manual))
#assert(align_of(Split) == align_of(Manual))
#assert(offset_of_by_string(Split, "head") == offset_of_by_string(Manual, "head"))
#assert(offset_of_by_string(Split, "tail") == offset_of_by_string(Manual, "tail"))
#assert(offset_of_by_string(Split, "flag") == offset_of_by_string(Manual, "flag"))

// Padding is generated, but it is still reported: 192 bytes total, 17 of them named.
#assert(intrinsics.layout_padding_of(Split) == 3*CACHE_LINE-17)
#assert(intrinsics.layout_tail_padding_of(Split) == CACHE_LINE-1)

// The rule is "round the previous field's end up to the stride", not "field i sits at i*N". A field
// wider than one line pushes the next one out by two lines, not one.
Wide :: struct #split(CACHE_LINE) {
	tag:  u8,
	body: [100]u8,
	end:  u8,
}
#assert(offset_of_by_string(Wide, "tag") == 0)
#assert(offset_of_by_string(Wide, "body") == 64)
#assert(offset_of_by_string(Wide, "end") == 192)
#assert(size_of(Wide) == 256)

// Parametric structs resolve the stride per instantiation, like any other layout property.
Box :: struct($T: typeid) #split(CACHE_LINE) {
	value: T,
	stamp: u64,
}
#assert(size_of(Box(u64)) == 2*CACHE_LINE)
#assert(size_of(Box([80]u8)) == 3*CACHE_LINE)
#assert(offset_of_by_string(Box([80]u8), "stamp") == 128)

main :: proc() {
	// The compiler made a promise at compile time; these are the same promises observed at run
	// time, on real addresses, which is the only way to catch a codegen that disagrees with
	// `size_of`.
	arr: [3]Split
	for i in 0..<3 {
		arr[i].head = u64(i) + 1
		arr[i].tail = u64(i) + 100
		arr[i].flag = u8(i)
	}

	base := uintptr(&arr[0])
	assert(uintptr(&arr[1])-base == 3*CACHE_LINE, "array stride must be one whole #split struct")
	assert(uintptr(&arr[2])-base == 6*CACHE_LINE, "array stride must be one whole #split struct")

	for i in 0..<3 {
		assert(arr[i].head == u64(i) + 1, "head round-trip")
		assert(arr[i].tail == u64(i) + 100, "tail round-trip")
		assert(arr[i].flag == u8(i), "flag round-trip")
	}

	// The fields of one struct must be at least a cache line apart, which is the whole point.
	first := &arr[0]
	assert(uintptr(&first.tail)-uintptr(&first.head) >= CACHE_LINE, "head and tail must not share a cache line")

	fmt.println("split tests: ok")
}
