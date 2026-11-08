#+dialect hela
package atomic_packed

Bad :: struct #packed {
	#atomic #share(w) head: u64,
}
