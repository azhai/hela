package split_plain

// No `#+dialect hela`: `#split` must be rejected, and the message must say how to opt in.
Bad :: struct #split(64) {
	a: u64,
	b: u64,
}
