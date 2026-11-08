#+dialect hela

package aosoa_width

E :: struct {
	x, y: f32,
}

// A block width of 3 would make every index a division instead of a shift.
Bad :: #aosoa[3][30]E
