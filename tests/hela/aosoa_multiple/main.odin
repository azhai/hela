#+dialect hela

package aosoa_multiple

E :: struct {
	x, y: f32,
}

// 100 elements do not divide into blocks of 8, and a partial block would have to be a different
// type: the count has to be a multiple of the width.
Bad :: #aosoa[8][100]E
