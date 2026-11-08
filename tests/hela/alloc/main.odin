#+dialect hela
#+analysis alloc

package main

import "core:fmt"

// Every allocation is visible: the allocator is an explicit argument. This is exactly the rule
// tina's static boot spec and opus's per-connection arena follow, now checked by the compiler.
main :: proc() {
	buf := make([]u8, 32, context.allocator)
	defer delete(buf, context.allocator)
	for i in 0..<len(buf) {
		buf[i] = u8(i)
	}
	sum := 0
	for v in buf {
		sum += int(v)
	}
	if sum != 496 {
		fmt.eprintln("FAIL: explicit allocator path produced wrong bytes")
		return
	}
	fmt.println("alloc tests: ok")
}
