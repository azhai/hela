#+dialect hela
// `#atomic` is a declaration, not a layout rule: the bytes are exactly what `#align(64)` alone
// would produce. What changes is that the compiler now checks the field can be accessed atomically
// and exports the concurrency contract in the layout manifest.
#+analysis sharing

package main

import "base:intrinsics"
import "core:fmt"

Cursors :: struct {
	#align(64) #atomic #share(producer) head: u64,
	#align(64) #atomic #share(consumer) tail: u64,
	#align(64) mask: u64,
}

#assert(size_of(Cursors) == 3 * 64)
#assert(align_of(Cursors) == 64)
#assert(offset_of_by_string(Cursors, "head") == 0)
#assert(offset_of_by_string(Cursors, "tail") == 64)
#assert(offset_of_by_string(Cursors, "mask") == 128)
#assert(intrinsics.layout_padding_of(Cursors) == 168)
#assert(intrinsics.layout_tail_padding_of(Cursors) == 56)

main :: proc() {
	c: Cursors
	c.head = 1
	c.tail = 2
	c.mask = 3
	if c.head != 1 || c.tail != 2 || c.mask != 3 {
		fmt.eprintln("FAIL: plain field access on an #atomic field")
		return
	}
	fmt.println("atomic tests: ok")
}
