#+dialect hela
package atomic_bad_type

// A 16-byte byte blob is not lock-free atomic on any target Hela builds for.
Bad :: struct {
	#atomic #share(w) payload: [16]u8,
}
