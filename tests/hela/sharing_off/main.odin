#+dialect hela
#+analysis !sharing

package sharing_off

// The escape hatch: the same false-sharing pair, with the analysis turned off for this file. Code
// that shares a line on purpose (a packed stat block read by many threads, say) can say so once
// instead of at every field.
On_Purpose :: struct {
	#share(reader_a) a: u64,
	#share(reader_b) b: u64,
}
