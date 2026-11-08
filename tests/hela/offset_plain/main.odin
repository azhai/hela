package offset_plain

// `#offset(N)` is a Hela feature: without the file header it must be rejected rather than quietly
// ignored, so an Odin file cannot start depending on a dialect the rest of the toolchain ignores.
Bad :: struct {
	a: u8,
	#offset(8) b: u32,
}
