#+dialect hela

package offset_conflict

// Both prefixes answer "where does this field go?", with different answers: `#offset` is an exact
// byte, `#align` the next multiple. Only one of them can be the declaration.
Bad :: struct {
	a: u8,
	#align(8) #offset(16) b: u32,
}
