#+dialect hela
// Everything in `core:hela/*` obeys one rule that the compiler now enforces: no hidden
// allocation. All memory is carved from a caller-owned arena, so the byte budget of a shard is
// visible at boot instead of being discovered by the allocator at 3 a.m.
#+analysis alloc

// A bump allocator over a caller-owned buffer, plus a fixed-capacity generational pool.
//
// This is the foundation the other `core:hela` packages sit on. It is deliberately not a general
// allocator: there is no free(), no coalescing, no metadata per allocation. `reset` is one store.
// The shape is from tina's `Grand_Arena` and opus's per-connection dynamic arena; the difference
// is that here the struct itself is `#explicit`, so the compiler checks there is no padding the
// reader cannot see.
package hela_mem

// Arena has no hidden bytes: a slice is pointer+length (16 B), then two ints. `#explicit` makes
// that a compile-time promise rather than a comment.
Arena :: struct #explicit {
	data:   []u8,
	offset: int,
	peak:   int,
}

#assert(size_of(Arena) == 32)
#assert(align_of(Arena) == 8)
#assert(offset_of_by_string(Arena, "data") == 0)
#assert(offset_of_by_string(Arena, "offset") == 16)
#assert(offset_of_by_string(Arena, "peak") == 24)

// init borrows `backing`; the arena never owns it and never frees it.
init :: proc(a: ^Arena, backing: []u8) {
	a.data   = backing
	a.offset = 0
	a.peak   = 0
}

// reset is O(1). Nothing allocated from the arena may be used afterwards.
reset :: proc(a: ^Arena) {
	a.offset = 0
}

used :: proc(a: ^Arena) -> int {
	return a.offset
}

// alloc_bytes returns a zero-free view of `size` bytes aligned to `alignment` (a power of two).
// The padding used for alignment is counted, so `used` describes the real byte budget.
alloc_bytes :: proc(a: ^Arena, size: int, alignment: int) -> (data: []u8, ok: bool) {
	if size <= 0 || alignment <= 0 || alignment & (alignment - 1) != 0 {
		return nil, false
	}
	base := uintptr(raw_data(a.data))
	cur  := base + uintptr(a.offset)
	mask := uintptr(alignment - 1)
	aligned := (cur + mask) & ~mask
	pad := int(aligned - cur)
	if a.offset + pad + size > len(a.data) {
		return nil, false
	}
	start := a.offset + pad
	data = a.data[start : start + size]
	a.offset = start + size
	if a.offset > a.peak {
		a.peak = a.offset
	}
	return data, true
}

// alloc_one carves one T, aligned to T's own alignment.
alloc_one :: proc(a: ^Arena, $T: typeid) -> (^T, bool) {
	bytes, ok := alloc_bytes(a, size_of(T), align_of(T))
	if !ok {
		return nil, false
	}
	return cast(^T)raw_data(bytes), true
}

// Pool is a fixed-capacity, generational slot table. Never a raw pointer: a stale handle fails
// its generation check instead of becoming a use-after-free. This is tina's Isolate_Handle idea
// reduced to its bytes.
Pool :: struct($T: typeid, $N: int) {
	slots:        [N]T,
	generations:  [N]u32,
	free_indices: [N]int,
	free_count:   int,
}

// Handle packs `index` in the low 32 bits and `generation` in the high 32 bits. Generation 0 is
// reserved for "never allocated", so handle 0 is always invalid.
Handle :: distinct u64
HANDLE_NONE :: Handle(0)

handle_index      :: proc(h: Handle) -> int {return int(u64(h) & 0xFFFFFFFF)}
handle_generation :: proc(h: Handle) -> u32 {return u32(u64(h) >> 32)}
make_handle       :: proc(index: int, generation: u32) -> Handle {
	return Handle(u64(generation) << 32 | u64(index))
}

// pool_init builds the free list in reverse so index 0 is handed out first (deterministic).
pool_init :: proc(p: ^Pool($T, $N)) {
	p.free_count = N
	for i in 0..<N {
		p.free_indices[i] = N - 1 - i
		p.generations[i] = 0
	}
}

// pool_alloc pops a slot and bumps its generation, invalidating every handle that used to name it.
pool_alloc :: proc(p: ^Pool($T, $N)) -> (h: Handle, ok: bool) {
	if p.free_count == 0 {
		return HANDLE_NONE, false
	}
	p.free_count -= 1
	index := p.free_indices[p.free_count]
	gen := p.generations[index] + 1
	if gen == 0 {
		gen = 1 // wrap: generation 0 is reserved
	}
	p.generations[index] = gen
	return make_handle(index, gen), true
}

// pool_get resolves a handle. It returns nil for a stale, freed or never-allocated handle.
pool_get :: proc(p: ^Pool($T, $N), h: Handle) -> ^T {
	index := handle_index(h)
	if index < 0 || index >= N || handle_generation(h) == 0 {
		return nil
	}
	if p.generations[index] != handle_generation(h) {
		return nil
	}
	for i in 0..<p.free_count {
		if p.free_indices[i] == index {
			return nil // currently free, even if the generation happens to match
		}
	}
	return &p.slots[index]
}

// pool_free invalidates the handle and returns the slot to the free list.
pool_free :: proc(p: ^Pool($T, $N), h: Handle) -> bool {
	index := handle_index(h)
	if index < 0 || index >= N || handle_generation(h) == 0 {
		return false
	}
	if p.generations[index] != handle_generation(h) {
		return false
	}
	if p.free_count >= N {
		return false
	}
	p.generations[index] += 1
	if p.generations[index] == 0 {
		p.generations[index] = 1
	}
	p.free_indices[p.free_count] = index
	p.free_count += 1
	return true
}
