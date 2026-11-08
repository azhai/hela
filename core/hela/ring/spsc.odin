#+dialect hela
// `#share(label)` names the code that writes a field; with `#+analysis sharing` the compiler checks
// that fields with different writers do not land on the same cache line. On this type that is the
// whole design, stated as an assertion the compiler keeps.
#+analysis sharing

// A bounded single-producer / single-consumer ring buffer, written so that its memory layout is
// the documentation.
//
// The whole point of this file is the shape of `Ring`:
//
//   cache line 0   head          only ever written by the producer thread
//   cache line 1   tail          only ever written by the consumer thread
//   cache line 2   slots, mask   read-only after `init`
//
// If `head` and `tail` shared a cache line, every `push` would invalidate the line the consumer is
// reading and every `pop` would invalidate the producer's. That is false sharing: the threads do
// not touch the same word, but the coherence protocol cannot tell, so each store drags a line
// between cores. On a two-socket machine it costs roughly an order of magnitude of throughput.
//
// The layout is written as three field-level `#align(Cache_Line)`: the compiler puts `head`, `tail`
// and the read-only tail on separate lines. `#atomic` declares that the two cursors are read/written
// with `core:sync` atomic operations, and `#share` names their writers; `-emit-layout` exports all
// three facts together, so `hela-layout --contract` can show who owns each line.
// and the read-only tail of the struct on line boundaries and nothing else, so there is no padding
// to hand-count (compare the `#explicit` spelling in `tests/hela/split`, which needs a `_: [N]u8`
// after every field). `tests/hela/ring/main.odin` asserts the offsets above at compile time.
//
// The algorithm is the classic Lamport/Vyukov bounded queue: `head` and `tail` are monotonically
// increasing 64-bit counters, never compared to a limit, so the wrap is a mask and not a modulo,
// and the `head - tail` difference is meaningful even across `u64` wraparound.
//
//   push: read head (own, relaxed); read tail (other, acquire); if full, fail; write slot;
//         publish head with release.
//   pop:  read tail (own, relaxed); read head (other, acquire); if empty, fail; read slot;
//         publish tail with release.
//
// One thread calls `push`, a different thread calls `pop`. Calling either from two threads at once
// is a data race; use `core:hela/queue` (MPSC) for that.
package ring

import "core:sync"

// The cache line size this layout is designed around. Kept as a literal, not read from
// `-layout-cache-line`, because the *code* depends on the padding widths while the *analysis* may
// reasonably use a different assumption (for example 128 on Apple Silicon).
Cache_Line :: 64

// spin_hint lets a caller back off without inventing its own import of `core:sync`. It also
// anchors that import for `-vet-unused`: Odin does not check a polymorphic procedure body until
// it is instantiated, so a package made only of polymorphic procs is (wrongly) reported as not
// using its imports.
spin_hint :: proc() {
	sync.cpu_relax()
}

Ring :: struct($T: typeid) {
	// Owned by the producer.
	#align(Cache_Line) #atomic #share(producer) head: u64,

	// Owned by the consumer.
	#align(Cache_Line) #atomic #share(consumer) tail: u64,

	// Read-only after `init`. `mask` is `len(slots)-1`, which requires a power-of-two capacity.
	// These two share a line on purpose: no thread writes them after `init`.
	#align(Cache_Line) slots: []T,
	mask: u64,
}

// init borrows `capacity` slots from `allocator`. `capacity` must be a power of two so that the
// index wrap is `value & mask` rather than a division; returns false otherwise.
init :: proc(r: ^Ring($T), capacity: int, allocator := context.allocator) -> bool {
	if capacity <= 0 || capacity & (capacity-1) != 0 {
		return false
	}
	r.slots = make([]T, capacity, allocator)
	if r.slots == nil {
		return false
	}
	r.mask = u64(capacity-1)
	sync.atomic_store(&r.head, u64(0))
	sync.atomic_store(&r.tail, u64(0))
	return true
}

// destroy releases the slots. The ring must not be in use.
destroy :: proc(r: ^Ring($T), allocator := context.allocator) {
	delete(r.slots, allocator)
	r.slots = nil
	r.mask = 0
	sync.atomic_store(&r.head, u64(0))
	sync.atomic_store(&r.tail, u64(0))
}

// capacity reports the fixed number of slots. Not named `cap`, to avoid shadowing the builtin.
capacity :: proc(r: ^Ring($T)) -> int {
	return len(r.slots)
}

// length reports how many values are currently buffered. It reads both cursors, so the value is a
// snapshot: by the time you look at it, the other thread may have moved. Not named `len`, to avoid
// shadowing the builtin.
length :: proc(r: ^Ring($T)) -> int {
	head := sync.atomic_load_explicit(&r.head, .Acquire)
	tail := sync.atomic_load_explicit(&r.tail, .Acquire)
	return int(head - tail)
}

// is_empty and is_full are `length` comparisons; they are hints, not synchronisation.
is_empty :: proc(r: ^Ring($T)) -> bool {return length(r) == 0}
is_full  :: proc(r: ^Ring($T)) -> bool {return length(r) == capacity(r)}

// push appends `value` and reports whether there was room. Producer thread only.
//
// `head` is read with relaxed ordering because this thread is the only writer, and the preceding
// slot write plus the release store of `head` is what makes `value` visible to the consumer.
push :: proc(r: ^Ring($T), value: T) -> bool {
	head := sync.atomic_load_explicit(&r.head, .Relaxed)
	tail := sync.atomic_load_explicit(&r.tail, .Acquire)
	if head - tail > r.mask {
		return false // full
	}
	r.slots[head & r.mask] = value
	sync.atomic_store_explicit(&r.head, head+1, .Release)
	return true
}

// pop removes and returns the oldest value. Consumer thread only.
pop :: proc(r: ^Ring($T)) -> (value: T, ok: bool) {
	tail := sync.atomic_load_explicit(&r.tail, .Relaxed)
	head := sync.atomic_load_explicit(&r.head, .Acquire)
	if tail == head {
		return {}, false // empty
	}
	value = r.slots[tail & r.mask]
	sync.atomic_store_explicit(&r.tail, tail+1, .Release)
	return value, true
}

// push_blocking retries `push` with `cpu_relax` between attempts. Consumer must make progress;
// there is no backoff beyond that, because a blocking SPSC queue that sleeps needs a futex and a
// futex needs a lock, which defeats the purpose.
push_blocking :: proc(r: ^Ring($T), value: T) {
	for !push(r, value) {
		sync.cpu_relax()
	}
}

// pop_blocking retries `pop` with `cpu_relax` between attempts.
pop_blocking :: proc(r: ^Ring($T)) -> T {
	for {
		if v, ok := pop(r); ok {
			return v
		}
		sync.cpu_relax()
	}
}
