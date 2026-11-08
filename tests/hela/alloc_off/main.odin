#+dialect hela
#+analysis !alloc

package alloc_off

// The escape hatch: the same implicit allocation is fine once the file says the analysis is off.
Ok :: proc() -> []u8 {
	return make([]u8, 8)
}
