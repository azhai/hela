#+dialect hela

// Tests for `core:hela/ring`.
//
// Two kinds of assertion, and both matter:
//
//  1. compile-time, on the layout itself — this is what Hela exists for;
//  2. run-time, on the queue being a queue — a perfectly aligned ring that loses values is worse
//     than a slow one.
package main

import "base:intrinsics"

import "core:fmt"
import "core:os"
import "core:thread"
import "core:time"

import "core:hela/ring"

Counters :: ring.Ring(u64)
Cache_Line :: ring.Cache_Line

// ---------------------------------------------------------------------------------------------
// 1. Layout
//
// If any of these fail, the producer and the consumer are now sharing a cache line and every
// `push` will invalidate the line the consumer is polling. Throughput does not degrade politely
// in that case; it falls off a cliff.
// ---------------------------------------------------------------------------------------------

#assert(size_of(Counters) == 3 * Cache_Line)
#assert(align_of(Counters) == Cache_Line)

#assert(offset_of_by_string(Counters, "head") == 0)
#assert(offset_of_by_string(Counters, "tail") == Cache_Line)
#assert(offset_of_by_string(Counters, "slots") == 2 * Cache_Line)

// The padding is the alignment's, not hand-written: 56 bytes between `head` and `tail`, 56 more
// between `tail` and `slots`, and 40 at the end so that an array of rings keeps the alignment.
// Stating the numbers here means a change to `Ring` cannot quietly change the byte map.
#assert(intrinsics.layout_padding_of(Counters) == 152)
#assert(intrinsics.layout_tail_padding_of(Counters) == 40)
#assert(intrinsics.layout_cache_lines_of(Counters) == 3)

// The property that actually matters, stated directly: the cursors are on different lines.
#assert(offset_of_by_string(Counters, "tail") - offset_of_by_string(Counters, "head") >= Cache_Line)

// ---------------------------------------------------------------------------------------------
// 2. Behaviour
// ---------------------------------------------------------------------------------------------

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

test_single_thread :: proc() {
	r: Counters
	if !ring.init(&r, 8) {
		fail("init(8) should succeed")
	}
	defer ring.destroy(&r)

	if ring.capacity(&r) != 8 {
		fail("cap = %d, want 8", ring.capacity(&r))
	}
	if !ring.is_empty(&r) {
		fail("fresh ring should be empty")
	}

	// Fill it exactly.
	for i in u64(0)..<8 {
		if !ring.push(&r, i*10) {
			fail("push %d should succeed", i)
		}
	}
	if !ring.is_full(&r) {
		fail("ring should be full after 8 pushes")
	}
	if ring.push(&r, 999) {
		fail("push into a full ring should fail")
	}
	if ring.length(&r) != 8 {
		fail("len = %d, want 8", ring.length(&r))
	}

	// FIFO order, and room again after each pop.
	for i in u64(0)..<8 {
		v, ok := ring.pop(&r)
		if !ok {
			fail("pop %d should succeed", i)
		}
		if v != i*10 {
			fail("pop %d = %d, want %d", i, v, i*10)
		}
	}
	if _, ok := ring.pop(&r); ok {
		fail("pop from an empty ring should fail")
	}
	if !ring.is_empty(&r) {
		fail("ring should be empty after draining")
	}
}

test_wraparound :: proc() {
	r: Counters
	if !ring.init(&r, 4) {fail("init(4) should succeed")}
	defer ring.destroy(&r)

	// Four laps of a four-slot ring: `head` and `tail` pass 16, so the `& mask` wrap is exercised
	// without the counters ever being compared to a bound.
	for lap in u64(0)..<4 {
		for i in u64(0)..<4 {
			v := lap*4 + i
			if !ring.push(&r, v) {
				fail("push %d (lap %d) should succeed", v, lap)
			}
		}
		for i in u64(0)..<4 {
			want := lap*4 + i
			v, ok := ring.pop(&r)
			if !ok {
				fail("pop %d (lap %d) should succeed", want, lap)
			}
			if v != want {
				fail("pop = %d, want %d", v, want)
			}
		}
	}
}

test_rejects_non_power_of_two :: proc() {
	r: Counters
	for bad in ([]int{0, -1, 3, 6, 100}) {
		if ring.init(&r, bad) {
			ring.destroy(&r)
			fail("init(%d) should be rejected: capacity must be a power of two", bad)
		}
	}
}

// ---------------------------------------------------------------------------------------------
// 3. Two threads
// ---------------------------------------------------------------------------------------------

ITEMS    :: 1_000_000
CAPACITY :: 1024

Producer_State :: struct {
	r:     ^Counters,
	items: u64,
}

Consumer_State :: struct {
	r:     ^Counters,
	items: u64,
	count: u64,
	sum:   u64,
	bad:   bool,
}

producer_proc :: proc(data: rawptr) {
	s := cast(^Producer_State)data
	for i in u64(0)..<s.items {
		ring.push_blocking(s.r, i)
	}
}

consumer_proc :: proc(data: rawptr) {
	s := cast(^Consumer_State)data
	expect := u64(0)
	for s.count < s.items {
		v, ok := ring.pop(s.r)
		if !ok {
			continue // empty: the producer has not caught up yet
		}
		if v != expect {
			s.bad = true
			return
		}
		expect += 1
		s.count += 1
		s.sum += v
	}
}

test_two_threads :: proc() {
	r: Counters
	if !ring.init(&r, CAPACITY) {
		fail("init(%d) should succeed", CAPACITY)
	}
	defer ring.destroy(&r)

	cstate := Consumer_State{r = &r, items = ITEMS}
	pstate := Producer_State{r = &r, items = ITEMS}

	start := time.now()

	ct := thread.create_and_start_with_data(&cstate, consumer_proc)
	if ct == nil {
		fail("could not start consumer thread")
	}

	pt := thread.create_and_start_with_data(&pstate, producer_proc)
	if pt == nil {
		fail("could not start producer thread")
	}

	thread.join(pt)
	thread.join(ct)
	thread.destroy(pt)
	thread.destroy(ct)

	elapsed := time.duration_seconds(time.since(start))

	if cstate.bad {
		fail("consumer saw an out-of-order or duplicated value")
	}
	if cstate.count != ITEMS {
		fail("consumer got %d values, want %d", cstate.count, ITEMS)
	}
	want_sum := u64(ITEMS*(ITEMS-1)/2)
	if cstate.sum != want_sum {
		fail("checksum = %d, want %d", cstate.sum, want_sum)
	}
	if !ring.is_empty(&r) {
		fail("ring should be empty after the run")
	}

	// Not an assertion: machine speed varies too much for CI. Printed so a human can compare a
	// layout change against the baseline. One million 8-byte messages, two threads.
	fmt.printf(
		"two-thread: %d items through a %d-slot ring in %.3f ms (%.1f M msg/s)\n",
		ITEMS, CAPACITY, elapsed*1000, f64(ITEMS)/elapsed/1.0e6,
	)
}

// ---------------------------------------------------------------------------------------------

main :: proc() {
	test_single_thread()
	test_wraparound()
	test_rejects_non_power_of_two()
	test_two_threads()
	bench_false_sharing()
	fmt.println("ring tests: ok")
}
