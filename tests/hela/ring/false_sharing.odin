#+dialect hela

// False sharing, stated as a layout difference and then measured.
//
// Two independent counters, two threads. Thread A increments `a`, thread B increments `b`. Nothing
// is written by both threads, so there is no data race and no synchronisation is needed — this is
// not a concurrency bug. It is a *layout* bug: if `a` and `b` happen to live in the same 64-byte
// line, every store invalidates the other core's copy, and the line bounces between cores on every
// iteration. Move `b` one cache line away and the same program gets several times faster, with no
// algorithmic change at all.
//
// That is the thesis of Hela in one program: layout is not an optimisation detail you add later,
// it is part of what the code means, and `#assert` can pin it down.
package main

import "base:intrinsics"

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import "core:hela/ring"

// ---------------------------------------------------------------------------------------------
// 1. The wrong layout, for contrast. Only compile-time facts here: a benchmark ratio between these
//    two rings turned out to be too sensitive to scheduling on this machine to print honestly.
// ---------------------------------------------------------------------------------------------

// The same algorithm as `ring.Ring`, with everything stacked on one cache line.
Bad_Ring :: struct #explicit #align(8) {
	head:  u64,
	tail:  u64,
	slots: []u64,
	mask:  u64,
}

#assert(size_of(Bad_Ring) == 40) // head, tail, slice header, mask: all inside one line
#assert(offset_of_by_string(Bad_Ring, "tail") - offset_of_by_string(Bad_Ring, "head") < 64)

// `ring.Ring` puts `head`, `tail` and `slots` on three separate lines. Both compile; only one of
// them will scale.
Ring_U64 :: ring.Ring(u64)

#assert(size_of(Ring_U64) == 3*ring.Cache_Line)
#assert(offset_of_by_string(Ring_U64, "tail") - offset_of_by_string(Ring_U64, "head") >= 64)

// ---------------------------------------------------------------------------------------------
// 2. The measurement
// ---------------------------------------------------------------------------------------------

Counters_Shared :: struct #explicit {
	a: u64, // same line as `b`
	b: u64,
}

Counters_Split :: struct #explicit #align(64) {
	a: u64,
	_: [56]u8,
	b: u64,
	_: [56]u8, // one full line each
}

#assert(offset_of_by_string(Counters_Shared, "b") - offset_of_by_string(Counters_Shared, "a") < 64)
#assert(offset_of_by_string(Counters_Split, "b") - offset_of_by_string(Counters_Split, "a") >= 64)
#assert(intrinsics.layout_padding_of(Counters_Split) == 0)
#assert(size_of(Counters_Split) == 128)

Counter_Job :: struct {
	cell:  ^u64,
	iters: u64,
}

// Both threads wait for the same flag, so the measurement covers the whole run of both loops
// instead of "thread A finished before thread B was even scheduled".
start_gate: u64

bump :: proc(data: rawptr) {
	j := cast(^Counter_Job)data
	for sync.atomic_load(&start_gate) == 0 {
		sync.cpu_relax()
	}
	// Atomic rather than `j.cell^ += 1`: an RMW cannot be coalesced into one store, so the loop
	// really does touch the line on every iteration. A plain store loop gets hoisted out by the
	// optimiser and then measures nothing at all — a trap worth knowing about.
	for _ in u64(0)..<j.iters {
		sync.atomic_add(j.cell, u64(1))
	}
}

bench_counters :: proc(split: bool, iters: u64) -> (mps: f64, total: u64) {
	on_one_line: Counters_Shared
	per_line:    Counters_Split

	pa, pb: Counter_Job
	if split {
		pa = Counter_Job{cell = &per_line.a, iters = iters}
		pb = Counter_Job{cell = &per_line.b, iters = iters}
	} else {
		pa = Counter_Job{cell = &on_one_line.a, iters = iters}
		pb = Counter_Job{cell = &on_one_line.b, iters = iters}
	}

	sync.atomic_store(&start_gate, u64(0))

	ta := thread.create_and_start_with_data(&pa, bump)
	tb := thread.create_and_start_with_data(&pb, bump)
	if ta == nil || tb == nil {
		return 0, 0
	}

	start := time.now()
	sync.atomic_store(&start_gate, u64(1))

	thread.join(ta)
	thread.join(tb)
	thread.destroy(ta)
	thread.destroy(tb)
	elapsed := time.duration_seconds(time.since(start))

	if split {
		total = per_line.a + per_line.b
	} else {
		total = on_one_line.a + on_one_line.b
	}
	return f64(2*iters)/elapsed/1.0e6, total
}

COUNTER_ITERS :: 4_000_000

// bench_false_sharing prints both variants. It fails the suite if the counters are wrong, but never
// on the ratio: the machine decides the ratio, and a box that schedules both threads on one core
// would report 1.0x with a perfectly good layout. The printed number is evidence, not a contract.
bench_false_sharing :: proc() {
	shared_rate, shared_total := bench_counters(false, COUNTER_ITERS)
	split_rate,  split_total  := bench_counters(true,  COUNTER_ITERS)

	want := u64(2*COUNTER_ITERS)
	if shared_total != want {
		fail("shared counters: %d increments, want %d", shared_total, want)
	}
	if split_total  != want {
		fail("split counters: %d increments, want %d", split_total, want)
	}

	ratio := 0.0
	if shared_rate > 0 {
		ratio = split_rate/shared_rate
	}

	fmt.printf("two counters, two threads, %d increments each:\n", COUNTER_ITERS)
	fmt.printf("  both on one cache line: %8.1f M inc/s\n", shared_rate)
	fmt.printf("  one line each:          %8.1f M inc/s  (%.2fx)\n", split_rate, ratio)
}
