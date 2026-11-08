#+dialect hela

package align_split

// `#split(64)` already puts every field on a 64-byte boundary, so a field-level `#align(16)` is
// either redundant or a contradiction, depending on the field.
Bad :: struct #split(64) {
	#align(16) a: u64,
	b: u64,
}
