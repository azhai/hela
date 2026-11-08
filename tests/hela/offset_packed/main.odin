#+dialect hela

package offset_packed

// A packed struct is defined by having no gaps; pinning a field to byte 8 is exactly a gap.
Bad :: struct #packed {
	a: u8,
	#offset(8) b: u32,
}
