#+dialect hela
package bit_not_field

import "base:intrinsics"

// A bit-segment mask is only meaningful for a `bit_field` type. A plain struct has fields, but
// no bit ownership for the compiler to report.
Plain :: struct {
	a: u32,
}

#assert(intrinsics.layout_bit_mask_of(Plain, "a") != 0)
