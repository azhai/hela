package align_plain

// No `#+dialect hela`: the field-level `#align` must be rejected, and the message must say how to
// opt in.
Bad :: struct {
	#align(64) a: u64,
	b: u64,
}
