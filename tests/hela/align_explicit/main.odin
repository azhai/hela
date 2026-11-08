#+dialect hela

package align_explicit

// `#align` inserts padding and `#explicit` forbids unnamed padding: the same bytes cannot be
// described both ways.
Bad :: struct #explicit {
	#align(64) a: u64,
	b: u64,
}
