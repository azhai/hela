#+dialect hela
#+analysis sharing

package sharing_misplaced

// A nested struct that carries '#share' annotations must start on a cache line boundary of its
// own. Its type's analysis computes cache lines from offset 0; if the enclosing struct starts it
// at byte 8, every line boundary inside it has moved and those results no longer describe where
// the fields actually live. The compiler reports this as a warning — the fix ('#align(64)' on the
// field) is mechanical, and the misplacement itself is not a false-sharing pair.
Inner :: struct {
	#share(worker) x: u64,
	_:               [56]u8,
}

Outer :: struct {
	lead:  u8,    // pushes Inner to byte 8
	inner: Inner, // starts at byte 8: warning, not an error
}

main :: proc() {
	o: Outer
	o.inner.x = 1
	_ = o.lead
}
