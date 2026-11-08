#+dialect hela
package bit_no_field

import "base:intrinsics"

Header :: bit_field u16 {
	kind: u8 | 3,
}

// A missing segment would otherwise look like "bits 0..0" and silently produce a wrong rule.
#assert(intrinsics.layout_bit_mask_of(Header, "nope") != 0)
