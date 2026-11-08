#+dialect hela
#+analysis alloc

package alloc_fail

// `make` without an allocator silently reaches into `context.allocator`. With the analysis on,
// that is a compile error rather than a hidden allocation in a hot path.
Bad :: proc() -> []u8 {
	return make([]u8, 8)
}
