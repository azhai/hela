#+dialect hela

package align_below

// A field can be pushed further out, never pulled in: placing a u64 at a 4-byte boundary would
// tell the backend to emit loads that the type does not actually allow.
Bad :: struct {
	a: u8,
	#align(4) b: u64,
}
