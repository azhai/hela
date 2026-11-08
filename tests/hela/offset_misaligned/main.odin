#+dialect hela

package offset_misaligned

// An absolute offset still has to respect the field type's own alignment: putting a u32 at byte 5
// would make every load of it unaligned, which the type does not promise.
Bad :: struct {
	a: u8,
	#offset(5) b: u32,
}
