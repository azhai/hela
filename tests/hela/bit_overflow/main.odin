#+dialect hela
package bit_overflow

import "base:intrinsics"

Header :: bit_field u16 {
	kind: u8 | 3,
}

// 8 does not fit in three bits. Encoded with a plain shift it would spill into `flags`, which is
// exactly the silent wire-format corruption these intrinsics exist to prevent.
#assert(intrinsics.layout_bit_encode_of(Header, "kind", 8) != 0)
