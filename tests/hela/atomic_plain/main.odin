package atomic_plain

// No '#+dialect hela': the dialect must not leak into plain Odin files.
Bad :: struct {
	#atomic #share(w) x: u64,
}
