#+dialect hela
#+analysis sharing

package sharing_fail

// Two writers on one cache line: the layout the compiler produces contradicts what the fields
// claim about who writes them. `#align(64)` on either field fixes it; that is what makes the
// message worth reading.
Bad :: struct {
	#share(producer) head: u64,
	#share(consumer) tail: u64,
}

// The same pair, one type apart: each writer lives in a different type, so neither type's own
// analysis can see the other. Only the enclosing struct flattens both and catches it — this is
// the case the per-type analysis is structurally blind to.
Tail_Writer :: struct {
	#share(left) tail_hot: u64,
	_:            [24]u8,
}

Head_Writer :: struct {
	#share(right) head_hot: u64,
	_:            [24]u8,
}

Cross_Bad :: struct {
	a: Tail_Writer, // tail_hot on bytes 0..8, cache line 0
	b: Head_Writer, // head_hot on bytes 32..40, cache line 0 — same line, different writers
}
