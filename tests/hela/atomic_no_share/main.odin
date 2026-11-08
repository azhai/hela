#+dialect hela
#+analysis sharing
package atomic_no_share

// Declaring a cross-thread field without naming its writer leaves the ownership map incomplete.
Bad :: struct {
	#atomic head: u64,
}
