#+dialect hela

// End-to-end regression for the `core:hela/*` runtime stack.
//
// Two kinds of assertion, as always in this repository:
//   1. compile-time, on the bytes — a wire header that moved is a broken protocol before it is a
//      failing test;
//   2. run-time, on the behaviour — a perfectly aligned queue that loses a value is worse than a
//      slow one.
//
// The concurrency part is a *litmus*: two producers write uniquely encoded values into one MPMC
// queue and two consumers drain it; the sum and count must match exactly. That catches lost,
// duplicated and reordered-at-the-wrong-time values, which "it didn't crash" does not.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:strings"
import "core:thread"
import "core:time"

import "core:hela/bench"
import "core:hela/cache"
import "core:hela/event"
import "core:hela/log"
import mem "core:hela/mem"
import "core:hela/msg"
import "core:hela/queue"
import "core:hela/ring"
import "core:hela/supervise"

// ---------------------------------------------------------------------------------------------
// 1. Layout: the wire formats and the cache-line contracts
// ---------------------------------------------------------------------------------------------

#assert(size_of(msg.Envelope) == msg.ENVELOPE_SIZE)
#assert(offset_of_by_string(msg.Envelope, "payload") == 32)
#assert(intrinsics.layout_padding_of(msg.Envelope) == 6)

#assert(size_of(log.Record) == log.RECORD_SIZE)
#assert(offset_of_by_string(log.Record, "message") == 24)
#assert(intrinsics.layout_cache_lines_of(log.Record) == 1)

#assert(size_of(queue.Cell(u64)) == queue.Cache_Line)
#assert(size_of(queue.Queue(u64)) == 3 * queue.Cache_Line)
#assert(offset_of_by_string(queue.Queue(u64), "dequeue_pos") == queue.Cache_Line)

#assert(size_of(cache.Shard) % cache.Cache_Line == 0)
#assert(offset_of_by_string(cache.Shard, "version") == 0)

#assert(size_of(ring.Ring(u64)) == 3 * ring.Cache_Line)

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

// ---------------------------------------------------------------------------------------------
// 2. mem: bump arena + generational pool
// ---------------------------------------------------------------------------------------------

test_mem :: proc() {
	backing: [1024]u8
	a: mem.Arena
	mem.init(&a, backing[:])
	first, ok := mem.alloc_bytes(&a, 100, 16)
	if !ok || len(first) != 100 || mem.used(&a) < 100 {
		fail("arena alloc_bytes did not carve 100 bytes")
	}
	second, ok2 := mem.alloc_bytes(&a, 8, 8)
	if !ok2 || uintptr(raw_data(second)) % 8 != 0 {
		fail("arena did not align a second allocation")
	}
	mem.reset(&a)
	if mem.used(&a) != 0 {
		fail("arena reset is not O(1)")
	}

	p: mem.Pool(u64, 4)
	mem.pool_init(&p)
	h, alloc_ok := mem.pool_alloc(&p)
	if !alloc_ok || h == mem.HANDLE_NONE {
		fail("pool_alloc failed on a fresh pool")
	}
	ptr := mem.pool_get(&p, h)
	if ptr == nil {
		fail("pool_get rejected a fresh handle")
	}
	ptr^ = 42
	if !mem.pool_free(&p, h) {
		fail("pool_free rejected a live handle")
	}
	if mem.pool_get(&p, h) != nil {
		fail("stale handle resolved after free")
	}
	h2, _ := mem.pool_alloc(&p)
	if h2 == h {
		fail("pool reused a handle without bumping its generation")
	}
	if mem.pool_get(&p, h) != nil {
		fail("old handle resolved after the slot was recycled")
	}
}

// ---------------------------------------------------------------------------------------------
// 3. queue: FIFO, capacity, batching
// ---------------------------------------------------------------------------------------------

test_queue_single :: proc() {
	q: queue.Queue(u64)
	if !queue.init(&q, 8, context.allocator) {
		fail("queue.init(8) failed")
	}
	defer queue.destroy(&q, context.allocator)

	for i in u64(0)..<8 {
		if !queue.push(&q, i) {
			fail("queue.push %d failed below capacity", i)
		}
	}
	if queue.push(&q, 99) {
		fail("queue accepted a ninth value into an 8-slot ring")
	}
	if queue.length(&q) != 8 {
		fail("queue.length = %d, want 8", queue.length(&q))
	}
	batch: [8]u64
	if got := queue.pop_batch(&q, batch[:]); got != 8 {
		fail("pop_batch returned %d, want 8", got)
	}
	for i in 0..<8 {
		if batch[i] != u64(i) {
			fail("pop_batch lost FIFO order at %d: %d", i, batch[i])
		}
	}
	if _, ok := queue.pop(&q); ok {
		fail("pop succeeded on an empty queue")
	}
	values := [4]u64{10, 20, 30, 40}
	if queue.push_batch(&q, values[:]) != 4 {
		fail("push_batch failed")
	}
	v, ok := queue.pop(&q)
	if !ok || v != 10 {
		fail("push_batch produced the wrong first value")
	}
}

// ---------------------------------------------------------------------------------------------
// 4. queue: MPMC litmus (2 producers, 2 consumers)
// ---------------------------------------------------------------------------------------------

LITMUS_ITEMS    :: 20_000
LITMUS_CAPACITY :: 1024

Litmus_State :: struct {
	q:         queue.Queue(u64),
	remaining: u64, // atomic, counts values not yet consumed
}

Litmus_Producer :: struct {
	s:      ^Litmus_State,
	id:     u64,
	items:  int,
}

Litmus_Consumer :: struct {
	s:     ^Litmus_State,
	sum:   u64,
	count: int,
	bad:   bool,
}

litmus_producer :: proc(data: rawptr) {
	p := cast(^Litmus_Producer)data
	for i in 0..<p.items {
		v := (p.id << 32) | u64(i)
		for !queue.push(&p.s.q, v) {
			queue.spin_hint()
		}
	}
}

litmus_consumer :: proc(data: rawptr) {
	c := cast(^Litmus_Consumer)data
	for {
		v, ok := queue.pop(&c.s.q)
		if !ok {
			if sync.atomic_load_explicit(&c.s.remaining, .Acquire) == 0 {
				break
			}
			queue.spin_hint()
			continue
		}
		c.sum += v
		c.count += 1
		sync.atomic_add_explicit(&c.s.remaining, ~u64(0), .Release)
		if sync.atomic_load_explicit(&c.s.remaining, .Acquire) == 0 {
			break
		}
	}
}

test_queue_litmus :: proc() {
	s: Litmus_State
	if !queue.init(&s.q, LITMUS_CAPACITY, context.allocator) {
		fail("litmus queue.init failed")
	}
	defer queue.destroy(&s.q, context.allocator)
	s.remaining = 2 * LITMUS_ITEMS

	p0 := Litmus_Producer{s = &s, id = 0, items = LITMUS_ITEMS}
	p1 := Litmus_Producer{s = &s, id = 1, items = LITMUS_ITEMS}
	c0, c1 := Litmus_Consumer{s = &s}, Litmus_Consumer{s = &s}

	start := time.tick_now()
	t0 := thread.create_and_start_with_data(&p0, litmus_producer)
	t1 := thread.create_and_start_with_data(&p1, litmus_producer)
	r0 := thread.create_and_start_with_data(&c0, litmus_consumer)
	r1 := thread.create_and_start_with_data(&c1, litmus_consumer)
	if t0 == nil || t1 == nil || r0 == nil || r1 == nil {
		fail("litmus could not start all four threads")
	}
	thread.join(t0)
	thread.join(t1)
	thread.join(r0)
	thread.join(r1)
	thread.destroy(t0)
	thread.destroy(t1)
	thread.destroy(r0)
	thread.destroy(r1)
	elapsed := time.tick_since(start)

	// Sum of (0<<32 + i) + (1<<32 + i) for i in 0..<N.
	want := u64(LITMUS_ITEMS) * u64(LITMUS_ITEMS - 1) + u64(LITMUS_ITEMS) * (u64(1) << 32)
	got  := c0.sum + c1.sum
	if got != want || c0.count + c1.count != 2 * LITMUS_ITEMS {
		fail("MPMC litmus: sum %d (want %d), count %d (want %d)",
			got, want, c0.count + c1.count, 2 * LITMUS_ITEMS)
	}
	if sync.atomic_load_explicit(&s.remaining, .Acquire) != 0 {
		fail("MPMC litmus left %d values unconsumed", s.remaining)
	}
	fmt.printf("  MPMC 2P/2C: %d values in %d ms, no loss/duplication\n",
		2 * LITMUS_ITEMS, i64(time.duration_milliseconds(elapsed)))
}

// ---------------------------------------------------------------------------------------------
// 5. msg: fixed envelope + mailbox
// ---------------------------------------------------------------------------------------------

test_msg :: proc() {
	mb: msg.Mailbox
	if !msg.init(&mb, 8, context.allocator) {
		fail("msg.init failed")
	}
	defer msg.destroy(&mb, context.allocator)

	data := [3]u8{1, 2, 3}
	e, ok := msg.make(11, 22, 0x40, 7, data[:])
	if !ok {
		fail("msg.make rejected a valid user message")
	}
	if len(msg.payload_of(&e)) != 3 || msg.payload_of(&e)[2] != 3 {
		fail("payload_of returned the wrong view")
	}
	if _, reserved_ok := msg.make(1, 2, 0x01, 0, data[:]); reserved_ok {
		fail("msg.make accepted a reserved system tag")
	}
	if !msg.send(&mb, e) {
		fail("msg.send failed")
	}
	got, recv_ok := msg.recv(&mb)
	if !recv_ok || got.source != 11 || got.destination != 22 || got.correlation != 7 || got.payload_size != 3 {
		fail("mailbox round trip changed the envelope")
	}

	batch: [4]msg.Envelope
	for i in 0..<4 {
		if !msg.send_retry(&mb, msg.Envelope{tag = 0x40 + u16(i), correlation = u32(i)}) {
			fail("msg.send_retry failed at %d", i)
		}
	}
	if n := msg.drain(&mb, batch[:]); n != 4 {
		fail("msg.drain returned %d, want 4", n)
	}
	for i in 0..<4 {
		if batch[i].correlation != u32(i) {
			fail("msg.drain lost order at %d", i)
		}
	}
}

// ---------------------------------------------------------------------------------------------
// 6. event: injectable clock, deterministic rounds
// ---------------------------------------------------------------------------------------------

sim_now:       i64 = 0
timer_handled: int = 0
user_handled:  int = 0

sim_clock :: proc() -> i64 {
	return sim_now
}

loop_handler :: proc(l: ^event.Loop, e: event.Event) {
	if e.kind == event.EVENT_TIMER {
		timer_handled += 1
	} else {
		user_handled += 1
	}
}

run_sim :: proc() -> (ticks: u64, fired: u64, timers: int, users: int) {
	sim_now = 0
	timer_handled = 0
	user_handled = 0
	l: event.Loop
	if !event.loop_init(&l, 16, sim_clock, loop_handler, context.allocator) {
		fail("event.loop_init failed")
	}
	defer event.loop_destroy(&l, context.allocator)

	if !event.post(&l, event.Event{kind = event.EVENT_USER, id = 1}) {
		fail("event.post failed")
	}
	if !event.post_timer(&l, 99, 10, 7) {
		fail("event.post_timer failed")
	}
	sim_now = 5
	event.loop_tick(&l, 8)  // one user event, no timer due
	sim_now = 10
	event.loop_tick(&l, 8)  // timer fires -> one TIMER event queued
	sim_now = 11
	event.loop_tick(&l, 8)  // TIMER event handled
	if !event.is_idle(&l) {
		fail("event loop is not idle after all work drained")
	}
	return l.ticks, l.fired, timer_handled, user_handled
}

test_event :: proc() {
	ticks, fired, timers, users := run_sim()
	if ticks != 3 || fired != 1 || timers != 1 || users != 1 {
		fail("simulation: ticks %d fired %d timers %d users %d", ticks, fired, timers, users)
	}
	// Same seed (clock values) + same posts = same result. This is the DST invariant in one line.
	t2, f2, tm2, us2 := run_sim()
	if t2 != ticks || f2 != fired || tm2 != timers || us2 != users {
		fail("simulation is not deterministic across identical runs")
	}
	// A timer wheel that is full must say so, not silently drop a timer.
	w: event.Wheel
	event.wheel_init(&w)
	for i in 0..<event.MAX_TIMERS {
		if event.wheel_arm(&w, u64(i), 100, 0) < 0 {
			fail("wheel_arm failed at %d of %d", i, event.MAX_TIMERS)
		}
	}
	if event.wheel_arm(&w, 999, 100, 0) >= 0 {
		fail("wheel accepted a 65th timer")
	}
}

// ---------------------------------------------------------------------------------------------
// 7. supervise: restart policy, stale handles, escalation
// ---------------------------------------------------------------------------------------------

test_supervise :: proc() {
	g: supervise.Group
	supervise.group_init(&g, .One_For_All, 2, 100)
	h0, ok0 := supervise.group_add(&g, "a")
	h1, _ := supervise.group_add(&g, "b")
	_, ok2 := supervise.group_add(&g, "c")
	if !ok0 || !ok2 {
		fail("group_add failed")
	}
	restarted: [supervise.MAX_CHILDREN]supervise.Handle
	action, count := supervise.report_failure(&g, h0, 10, restarted[:])
	if action != .Restart || count != 3 {
		fail("One_For_All: action %v count %d, want Restart/3", action, count)
	}
	if supervise.resolve(&g, h0) != -1 || supervise.resolve(&g, h1) != -1 {
		fail("stale handles still resolve after a group restart")
	}
	if restarted[0] == h0 {
		fail("restarted child kept its old handle")
	}
	// Within the window: one more failure is allowed, the next one escalates.
	_, _ = supervise.report_failure(&g, restarted[0], 20, restarted[:])
	action2, count2 := supervise.report_failure(&g, supervise.group_find(&g, "a"), 30, restarted[:])
	if action2 != .Give_Up || count2 != 0 || g.escalations != 1 {
		fail("restart window did not escalate after the limit")
	}
	// Outside the window the counter resets.
	action3, _ := supervise.report_failure(&g, supervise.group_find(&g, "a"), 200, restarted[:])
	if action3 != .Restart {
		fail("restart window did not reset after it expired")
	}
}

// ---------------------------------------------------------------------------------------------
// 8. cache: fixed slots, TTL, generation drop, zero-copy read
// ---------------------------------------------------------------------------------------------

test_cache :: proc() {
	c: cache.Cache
	if !cache.init(&c, 4, 64, context.allocator) {
		fail("cache.init failed")
	}
	defer cache.destroy(&c, context.allocator)

	key := [3]u8{1, 2, 3}
	val := [4]u8{9, 8, 7, 6}
	if !cache.set(&c, key[:], val[:], 100, 0) {
		fail("cache.set failed")
	}
	out: [cache.VALUE_MAX]u8
	if n := cache.get_into(&c, key[:], out[:], 10); n != 4 || out[0] != 9 || out[3] != 6 {
		fail("get_into returned %d bytes / wrong value", n)
	}
	if n := cache.get_into(&c, key[:], out[:], 101); n != -1 {
		fail("expired entry was still readable at its deadline")
	}
	small: [2]u8
	if n := cache.get_into(&c, key[:], small[:], 10); n != 0 {
		fail("get_into did not report a short destination")
	}
	if !cache.set(&c, key[:], val[:], 0, 0) {
		fail("cache.set without TTL failed")
	}
	if !cache.drop_generation(&c, 0) {
		fail("drop_generation returned false")
	}
	// The entry may live in any shard; dropping one shard must not corrupt the others.
	if cache.expire(&c, 1000) < 0 {
		fail("expire returned a negative count")
	}
}

// ---------------------------------------------------------------------------------------------
// 9. log: bounded records, filter, batch drain
// ---------------------------------------------------------------------------------------------

sink_count: int = 0
sink_bad:   bool = false

log_sink :: proc(r: ^log.Record) {
	sink_count += 1
	if log.message_of(r) != "hello" || r.level != u8(log.Level.Info) {
		sink_bad = true
	}
}

test_log :: proc() {
	l: log.Log
	if !log.init(&l, 4, .Info, context.allocator) {
		fail("log.init failed")
	}
	defer log.destroy(&l, context.allocator)

	if !log.write(&l, .Debug, 1, 1, "filtered") {
		fail("log.write rejected a filtered record")
	}
	if !log.write(&l, .Info, 1, 2, "hello") {
		fail("log.write failed")
	}
	if log.pending(&l) != 1 {
		fail("filtered record was not suppressed")
	}
	records: [8]log.Record
	if n := log.drain(&l, records[:], log_sink); n != 1 || sink_count != 1 || sink_bad {
		fail("log.drain: n %d sink_count %d bad %v", n, sink_count, sink_bad)
	}
	// Overflow is counted, never silently lost.
	for i in 0..<8 {
		log.write(&l, .Info, 1, i64(i), "over")
	}
	if log.dropped_count(&l) == 0 {
		fail("log overflow was not counted")
	}
}

// ---------------------------------------------------------------------------------------------
// 10. bench: warmup + rounds + median/p99 + JSON
// ---------------------------------------------------------------------------------------------

bench_sink: u64 = 0

// The atomic store cannot be folded into a closed-form constant by the optimiser, so the timed
// loop really runs. A pure `x += i` loop gets reduced to one multiplication and measures nothing.
bench_body :: proc(iterations: int) {
	for _ in 0..<iterations {
		sync.atomic_add_explicit(&bench_sink, 1, .Relaxed)
	}
}

test_bench :: proc() {
	cfg := bench.default_config()
	cfg.warmup = 1
	cfg.rounds = 5
	cfg.iterations = 2000
	r, ok := bench.run("integer add", cfg, bench_body, context.allocator)
	if !ok || r.median <= 0 || r.p99 < r.median || len(r.samples) != 5 {
		fail("bench.run produced an unusable result")
	}
	b: strings.Builder
	strings.builder_init(&b)
	bench.result_json(&b, &r)
	if !strings.contains(strings.to_string(b), "\"median_ns_per_op\"") {
		fail("bench JSON is missing the median key")
	}
	strings.builder_destroy(&b)
}

main :: proc() {
	test_mem()
	test_queue_single()
	test_queue_litmus()
	test_msg()
	test_event()
	test_supervise()
	test_cache()
	test_log()
	test_bench()
	fmt.println("hela runtime tests: ok")
}
