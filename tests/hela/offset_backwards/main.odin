#+dialect hela

package offset_backwards

// A pin that lands inside the previous field is not a layout, it is an overlap. The prefix declares
// the gap in front of the field; it cannot delete bytes that are already there.
Bad :: struct {
	#offset(0) a: u64,
	#offset(4) b: u32,
}
