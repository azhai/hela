#+dialect hela
#+analysis sharing

// False sharing at the array boundary, which no single type can see from the inside.
//
// A struct's own analysis compares its fields; it cannot know that `[N]T` or `make([]T, n)`
// repeats it. If T is not a whole number of cache lines, element i's tail and element i+1's head
// end up in the same line, and two threads that each own one element invalidate each other on
// every write — without sharing a single field. This is the shape `#+analysis sharing` warns
// about on the type, and this file is the measurement behind that rule.
package array_share

import "base:intrinsics"

import "core:fmt"
import "core:thread"
import "core:time"

CACHE_LINE :: 64

// `[dynamic]T` is a 40-byte header, so 40-byte elements put element i and element i+1 in one
// line: 40 and 40 share bytes 0..63. This is the shape a real program reaches for by accident
// (`make([][dynamic]Hit, threads)`).
List_Plain :: struct {
	list: [dynamic]u64,
}

#assert(size_of(List_Plain) == 40)
#assert(size_of(List_Plain) % CACHE_LINE != 0) // why the array case is a false-sharing case

// The shape the analysis asks for: one writer-bearing element per cache line.
List_Line :: struct #align(CACHE_LINE) {
	#share(worker) list: [dynamic]u64,
	_:                     [CACHE_LINE - size_of([dynamic]u64)]u8,
}

#assert(size_of(List_Line) == CACHE_LINE)
#assert(align_of(List_Line) == CACHE_LINE)
#assert(intrinsics.layout_cache_lines_of(List_Line) == 1)

THREADS  :: 4
APPENDS  :: 2_000_000

plain: [THREADS]List_Plain
lined: [THREADS]List_Line

push_plain :: proc(data: rawptr) {
	l := cast(^List_Plain)data
	for _ in 0..<APPENDS {
		append(&l.list, u64(1))
	}
}

push_lined :: proc(data: rawptr) {
	l := cast(^List_Line)data
	for _ in 0..<APPENDS {
		append(&l.list, u64(1))
	}
}

// Both variants do the same work, with the same allocator traffic (the backing arrays are sized
// up front, so an append writes only the header). The only difference is which line the header
// lives in.
run :: proc(lined_layout: bool) -> time.Duration {
	// Each run starts from empty: the backing arrays keep their capacity, so every append below
	// writes only the header — the thing whose cache line is under test.
	for i in 0..<THREADS {
		if lined_layout {
			clear(&lined[i].list)
		} else {
			clear(&plain[i].list)
		}
	}
	ths: [THREADS]^thread.Thread
	start := time.tick_now()
	for i in 0..<THREADS {
		if lined_layout {
			ths[i] = thread.create_and_start_with_data(&lined[i], push_lined)
		} else {
			ths[i] = thread.create_and_start_with_data(&plain[i], push_plain)
		}
	}
	for i in 0..<THREADS {
		thread.join(ths[i])
		thread.destroy(ths[i])
	}
	return time.tick_since(start)
}

bench :: proc() {
	for i in 0..<THREADS {
		plain[i].list = make([dynamic]u64, 0, APPENDS)
		lined[i].list = make([dynamic]u64, 0, APPENDS)
	}
	defer {
		for i in 0..<THREADS {
			delete(plain[i].list)
			delete(lined[i].list)
		}
	}

	// Warm up, then keep the best of a few runs: scheduling noise only ever makes a run slower.
	run(false)
	run(true)
	best_plain := time.Duration(max(i64))
	best_lined := time.Duration(max(i64))
	for _ in 0..<3 {
		if d := run(false); d < best_plain { best_plain = d }
		if d := run(true);  d < best_lined { best_lined = d }
	}

	total := u64(THREADS*APPENDS)
	got_plain, got_lined := u64(0), u64(0)
	for i in 0..<THREADS {
		got_plain += u64(len(plain[i].list))
		got_lined += u64(len(lined[i].list))
	}
	if got_plain != total || got_lined != total {
		fmt.panicf("appends lost: plain %d / lined %d, want %d", got_plain, got_lined, total)
	}

	ratio := 0.0
	if best_plain > 0 {
		ratio = f64(best_plain) / f64(best_lined)
	}
	fmt.printf("array elements, %d threads x %d appends:\n", THREADS, APPENDS)
	fmt.printf("  40 B elements (i and i+1 share a line): %v\n", best_plain)
	fmt.printf("  64 B elements, one line each:           %v  (%.2fx)\n", best_lined, ratio)
	fmt.printf("array share tests: ok\n")
}

main :: proc() {
	bench()
}
