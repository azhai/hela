#+dialect hela
#+analysis alloc
#+analysis sharing

// Bounded MPMC queue (Vyukov's array-based algorithm). One implementation covers SPSC, MPSC and
// MPMC: any number of producers may call `push`, any number of consumers may call `pop`.
//
// Why this shape is written with Hela's field prefixes instead of comments:
//
//   line 0  enqueue_pos   only producers CAS it
//   line 1  dequeue_pos   only consumers CAS it
//   line 2  cells, mask   read-only after init
//
// The per-cell `sequence` is the classic ticket: cell i starts with sequence == i, a producer
// claims it when sequence == pos and publishes pos+1, a consumer claims it when sequence ==
// pos+1 and publishes pos+capacity. Absolute monotonically increasing positions (never modulo)
// mean `pos & mask` is the index and `i64(seq) - i64(pos)` stays meaningful across u64 wrap.
//
// tina's SPSC ring is the same idea with one producer and one consumer; here the cursors are
// CAS'd instead of stored, which is the only real difference.
package queue

import "core:sync"

Cache_Line :: 64

// spin_hint is the caller-side backoff primitive. It also anchors the `core:sync` import for
// `-vet-unused`: Odin does not check polymorphic procedure bodies until they are instantiated, so
// a package containing only polymorphic procs is (wrongly) reported as not using its imports.
spin_hint :: proc() {
	sync.cpu_relax()
}

// Every cell occupies exactly one cache line, so two adjacent slots are never invalidated by the
// same coherence traffic. The sequence is the only field written by both sides.
Cell :: struct($T: typeid) #align(Cache_Line) {
	#atomic #share(slot) sequence: u64,
	data:                         T,
}

Cell_U64 :: Cell(u64)
#assert(size_of(Cell_U64) == Cache_Line)
#assert(align_of(Cell_U64) == Cache_Line)
#assert(offset_of_by_string(Cell_U64, "sequence") == 0)
#assert(offset_of_by_string(Cell_U64, "data") == 8)

Queue :: struct($T: typeid) {
	#align(Cache_Line) #atomic #share(producers) enqueue_pos: u64,
	#align(Cache_Line) #atomic #share(consumers) dequeue_pos: u64,
	#align(Cache_Line) cells: []Cell(T),
	mask: u64,
}

Queue_U64 :: Queue(u64)
#assert(size_of(Queue_U64) == 3 * Cache_Line)
#assert(offset_of_by_string(Queue_U64, "enqueue_pos") == 0)
#assert(offset_of_by_string(Queue_U64, "dequeue_pos") == Cache_Line)
#assert(offset_of_by_string(Queue_U64, "cells") == 2 * Cache_Line)

// init borrows `capacity` cells. Capacity must be a power of two so the wrap is a mask.
init :: proc(q: ^Queue($T), capacity: int, allocator := context.allocator) -> bool {
	if capacity <= 0 || capacity & (capacity - 1) != 0 {
		return false
	}
	q.cells = make([]Cell(T), capacity, allocator)
	if q.cells == nil {
		return false
	}
	q.mask = u64(capacity - 1)
	for i in 0..<capacity {
		sync.atomic_store_explicit(&q.cells[i].sequence, u64(i), .Relaxed)
	}
	sync.atomic_store_explicit(&q.enqueue_pos, 0, .Relaxed)
	sync.atomic_store_explicit(&q.dequeue_pos, 0, .Relaxed)
	return true
}

destroy :: proc(q: ^Queue($T), allocator := context.allocator) {
	delete(q.cells, allocator)
	q.cells = nil
	q.mask = 0
}

capacity :: proc(q: ^Queue($T)) -> int {
	return len(q.cells)
}

// length is a snapshot: by the time it is read, another thread may have moved either cursor.
length :: proc(q: ^Queue($T)) -> int {
	// Relaxed is correct here: this is a hint, not synchronisation, and the cursors are CAS'd
	// with relaxed success ordering (the release is on the cell's sequence, not the cursor).
	enq := sync.atomic_load_explicit(&q.enqueue_pos, .Relaxed)
	deq := sync.atomic_load_explicit(&q.dequeue_pos, .Relaxed)
	return int(enq - deq)
}

// push appends `value`. Returns false when the queue is full; never blocks.
push :: proc(q: ^Queue($T), value: T) -> bool {
	pos := sync.atomic_load_explicit(&q.enqueue_pos, .Relaxed)
	for {
		cell := &q.cells[int(pos & q.mask)]
		seq := sync.atomic_load_explicit(&cell.sequence, .Acquire)
		dif := i64(seq) - i64(pos)
		if dif == 0 {
			current, won := sync.atomic_compare_exchange_weak_explicit(
				&q.enqueue_pos, pos, pos + 1, .Relaxed, .Relaxed)
			if won {
				break
			}
			pos = current
		} else if dif < 0 {
			return false // full
		} else {
			pos = sync.atomic_load_explicit(&q.enqueue_pos, .Relaxed)
		}
	}
	cell := &q.cells[int(pos & q.mask)]
	cell.data = value
	// Release: the data write above must be visible before the consumer sees this sequence.
	sync.atomic_store_explicit(&cell.sequence, pos + 1, .Release)
	return true
}

// pop removes the oldest value. Returns ok == false when the queue is empty.
pop :: proc(q: ^Queue($T)) -> (value: T, ok: bool) {
	pos := sync.atomic_load_explicit(&q.dequeue_pos, .Relaxed)
	for {
		cell := &q.cells[int(pos & q.mask)]
		seq := sync.atomic_load_explicit(&cell.sequence, .Acquire)
		dif := i64(seq) - i64(pos + 1)
		if dif == 0 {
			current, won := sync.atomic_compare_exchange_weak_explicit(
				&q.dequeue_pos, pos, pos + 1, .Relaxed, .Relaxed)
			if won {
				break
			}
			pos = current
		} else if dif < 0 {
			return {}, false // empty
		} else {
			pos = sync.atomic_load_explicit(&q.dequeue_pos, .Relaxed)
		}
	}
	cell := &q.cells[int(pos & q.mask)]
	value = cell.data
	// Free the slot for the producer that will come around to it again.
	sync.atomic_store_explicit(&cell.sequence, pos + q.mask + 1, .Release)
	return value, true
}

// push_batch / pop_batch amortise the cursor traffic. Returning the count keeps the caller in
// charge of what to do with a partially filled batch (tina drains inbound mailboxes exactly
// this way).
push_batch :: proc(q: ^Queue($T), values: []T) -> int {
	pushed := 0
	for v in values {
		if !push(q, v) {
			break
		}
		pushed += 1
	}
	return pushed
}

pop_batch :: proc(q: ^Queue($T), dst: []T) -> int {
	popped := 0
	for &slot in dst {
		v, ok := pop(q)
		if !ok {
			break
		}
		slot = v
		popped += 1
	}
	return popped
}

