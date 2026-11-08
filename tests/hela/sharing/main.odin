#+dialect hela
#+analysis sharing

// `#share(label)` names the code that writes a field. With `#+analysis sharing` the compiler
// compares those claims against the layout it actually produced, and reports the case that costs
// the most and shows up the least: two writers on one cache line.
//
// This is the one part of Hela that cannot be a `#assert`, because it is not about one type's bytes
// but about two fields' *relationship* to a line. `#assert(offset_of(...) >= 64)` works when you
// know the pair to write down; `#share` is what tells the compiler which pairs exist.
//
// Every type below is also a whole number of cache lines, because a type that carries writers is
// repeated by `[N]T` and `make([]T, n)`: if an element is not line-sized, element i's tail shares
// a line with element i+1's head, and the analysis warns about it on the type. The shapes here are
// the shapes you want in a real program.
package sharing

import "base:intrinsics"
import "core:fmt"

CACHE_LINE :: 64

// Two writers, two lines: what `#share` is supposed to find nothing wrong with.
Separated :: struct {
	#align(CACHE_LINE) #share(producer) head: u64,
	#align(CACHE_LINE) #share(consumer) tail: u64,
}

// One writer, one line: sharing is fine because the same code writes both. The padding is not
// about these two fields — it makes the whole type one cache line, so an array of it gives every
// element its own line.
Grouped :: struct #align(CACHE_LINE) {
	#share(worker) hits:   u64,
	#share(worker) misses: u64,
	_:                     [CACHE_LINE - 2*size_of(u64)]u8,
}

// No labels: the analysis says nothing. An unlabelled field may be read-only, or written by
// everything; guessing either way would produce noise.
Unannotated :: struct {
	a: u64,
	b: u64,
}

// Cross-type: the two writers live in different types, so neither type's own analysis can see
// the pair — each one only knows its own bytes. The enclosing struct flattens both and compares
// across the boundary between them. Here the boundary lands between cache lines, which is what
// `#align` on a nested field is for.
Left_Side :: struct #align(CACHE_LINE) {
	#share(a_write) cursor: u64,
	_:              [CACHE_LINE - size_of(u64)]u8,
}

Right_Side :: struct #align(CACHE_LINE) {
	#share(b_write) epoch: u64,
	_:              [CACHE_LINE - size_of(u64)]u8,
}

Separated_Nested :: struct #align(CACHE_LINE) {
	a: Left_Side,  // cursor on cache line 0
	b: Right_Side, // epoch on cache line 1
}

#assert(intrinsics.layout_cache_lines_of(Separated) == 2)
#assert(offset_of_by_string(Separated, "head")/CACHE_LINE != offset_of_by_string(Separated, "tail")/CACHE_LINE)
#assert(offset_of_by_string(Grouped, "hits")/CACHE_LINE == offset_of_by_string(Grouped, "misses")/CACHE_LINE)
#assert(size_of(Left_Side) == CACHE_LINE) // puts b.epoch (at offset 0 of Right_Side) on line 1
#assert(offset_of_by_string(Separated_Nested, "b") == CACHE_LINE)

// The property the compiler warns about when it does not hold: no writer-bearing type may straddle
// elements, so its size must be a whole number of cache lines.
#assert(size_of(Grouped) % CACHE_LINE == 0)
#assert(size_of(Separated_Nested) % CACHE_LINE == 0)

main :: proc() {
	s: Separated
	s.head = 1
	s.tail = 2

	if uintptr(&s.head)/CACHE_LINE == uintptr(&s.tail)/CACHE_LINE {
		fmt.panicf("head and tail are on the same cache line")
	}

	// What the type-level rule buys: element i and element i+1 of an array never share a line,
	// at run time, whatever the allocator handed back.
	elems := make([]Grouped, 4)
	defer delete(elems)
	for i in 0..<len(elems)-1 {
		if uintptr(&elems[i].hits)/CACHE_LINE == uintptr(&elems[i+1].hits)/CACHE_LINE {
			fmt.panicf("array elements %d and %d share a cache line", i, i+1)
		}
	}
	fmt.println("sharing tests: ok")
}
