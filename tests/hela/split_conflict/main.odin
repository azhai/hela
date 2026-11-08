#+dialect hela

package split_conflict

// Both tags claim to define the whole layout: `#split(64)` fixes every offset, so `#explicit` has
// nothing left to check. Exactly one of them may be used.
Bad :: struct #split(64) #explicit {
	a: u64,
	b: u64,
}
