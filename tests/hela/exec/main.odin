#+dialect hela
// End-to-end regression for `core:hela/exec`, the thread-per-core / shared-nothing runtime.
//
// Two kinds of assertion, as everywhere else in this repository:
//   1. compile-time, on the bytes — the runtime header and every worker band are checked against
//      declared cache-line boundaries, and the envelope wire format is locked by `msg.Envelope`;
//   2. run-time, on the behaviour — a perfectly aligned SPSC matrix that loses a message is still
//      a broken runtime, so the litmus sums uniquely encoded values across all deliveries.
//
// Since M20 the batch is driven by REAL kernel I/O, not by a seed that invents messages. The
// controller writes one 8-byte trigger into a dedicated pipe per worker; that worker's own kqueue
// reports readiness, `io.poll` normalizes it into a `Completion`, `event.loop_tick` dispatches an
// EVENT_IO, and only THEN does the worker send its PER_PAIR * WORKERS envelopes over the SPSC
// matrix. So the whole chain is under test:
//
//   pipe -> kernel -> per-core poller -> event.Loop -> io_handler -> SPSC ring -> handler
//
// The litmus is stronger than "everyone exited": every message carries a distinct integer, and
// the sum of all delivered values must equal the sum of all sent values. Loss, duplication and
// double delivery all change the sum.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

import "core:hela/cache"
import "core:hela/exec"
import io "core:hela/io"
import "core:hela/msg"
import "core:hela/supervise"

WORKERS  :: 4
PER_PAIR :: 256
// Deliberately FAR below PER_PAIR. Under M19 this configuration deadlocks: every worker fills
// every outbound channel while seeding and nobody reaches the drain loop. M23's `flow` pump is
// the only reason this batch completes, so the capacity itself is part of the assertion.
CAPACITY :: 8
TOTAL    :: WORKERS * WORKERS * PER_PAIR // 4096 deliveries

#assert(size_of(exec.Runtime) % exec.Cache_Line == 0)
#assert(offset_of_by_string(exec.Runtime, "sent") == exec.Cache_Line)
#assert(offset_of_by_string(exec.Runtime, "stopping") == 2 * exec.Cache_Line)
#assert(offset_of_by_string(exec.Worker, "handled") == exec.Cache_Line)
#assert(offset_of_by_string(exec.Worker, "arena") == 2 * exec.Cache_Line)
#assert(offset_of_by_string(exec.Worker, "io_src") % exec.Cache_Line == 0)
#assert(offset_of_by_string(exec.Worker, "stopped") % exec.Cache_Line == 0)
#assert(size_of(msg.Envelope) == msg.ENVELOPE_SIZE)
#assert(size_of(io.Completion) == io.COMPLETION_SIZE)
#assert(intrinsics.layout_cache_lines_of(msg.Envelope) == 2)

// One pipe per worker, created by the controller before `start` and only read by that worker.
PIPES: [WORKERS][2]i32

g_io_bad: u64

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

// seed runs once on each worker: register this worker's OWN read fd with its OWN poller. It
// deliberately sends no messages. The batch only starts when the kernel reports readiness.
seed :: proc(w: ^exec.Worker) {
	if !io.add(&w.io_src, PIPES[w.id][0], u16(w.id + 1), io.WANT_READ) {
		fail("worker %d could not register its pipe", w.id)
	}
}

// io_handler runs inside `event.loop_tick`, on the worker's own thread, after a real kernel
// completion. It is the only place the batch is produced, so a broken I/O source fails the
// litmus instead of quietly falling back to an invented workload.
io_handler :: proc(w: ^exec.Worker, c: io.Completion) {
	if c.kind != .Read || c.handle != u32(PIPES[w.id][0]) || c.tag != u16(w.id + 1) {
		sync.atomic_add_explicit(&g_io_bad, 1, .Relaxed)
		return
	}
	if c.flags != 0 || c.errno != 0 {
		sync.atomic_add_explicit(&g_io_bad, 1, .Relaxed)
		return
	}
	trigger: [8]u8
	if io.read_fd(i32(c.handle), trigger[:]) != 8 {
		sync.atomic_add_explicit(&g_io_bad, 1, .Relaxed)
		return
	}
	for i in 0..<8 {
		if trigger[i] != u8(w.id + 1) {
			sync.atomic_add_explicit(&g_io_bad, 1, .Relaxed)
			return
		}
	}

	for dst in 0..<WORKERS {
		for seq in 0..<PER_PAIR {
			v := u64(w.id) * u64(WORKERS * PER_PAIR) + u64(dst) * u64(PER_PAIR) + u64(seq)
			e := msg.Envelope{
				tag           = msg.USER_TAG_BASE,
				correlation   = u32(seq),
				payload_size  = 8,
			}
			exec.encode(e.payload[:], v)
			if !exec.send(w, dst, e) {
				sync.atomic_add_explicit(&g_io_bad, 1, .Relaxed)
				return
			}
		}
	}
}

// handler runs on the receiving worker's thread. It verifies the per-worker cache (shared-nothing:
// no other worker can touch it) with a set/get_into round trip, then accumulates the litmus sum on
// the worker's own cache line.
handler :: proc(w: ^exec.Worker, e: ^msg.Envelope) {
	v := exec.decode(e.payload[:])
	sync.atomic_add_explicit(&w.app_sum, v, .Relaxed)

	key: [8]u8
	key[0] = u8(e.correlation & 15) // 16 distinct keys per worker, 64 slots in its cache
	value := e.payload[:8]
	if !cache.set(&w.cache, key[:], value, 0, 0) {
		sync.atomic_add_explicit(&w.app_bad, 1, .Relaxed)
		return
	}
	out: [cache.VALUE_MAX]u8
	if cache.get_into(&w.cache, key[:], out[:], 0) != 8 {
		sync.atomic_add_explicit(&w.app_bad, 1, .Relaxed)
		return
	}
	for i in 0..<8 {
		if out[i] != value[i] {
			sync.atomic_add_explicit(&w.app_bad, 1, .Relaxed)
			return
		}
	}
}

main :: proc() {
	if !io.FULLY_SUPPORTED {
		fmt.println("exec thread-per-core tests: skipped (no I/O backend on this target)")
		return
	}

	for i in 0..<WORKERS {
		r, w, ok := io.make_pipe()
		if !ok {
			fail("make_pipe %d failed (errno %d)", i, io.os_errno())
		}
		PIPES[i][0] = r
		PIPES[i][1] = w
	}

	// Runtime is ~40 KB and has a 64-byte alignment requirement; allocate it rather than putting
	// it on the main thread's stack.
	rt := new(exec.Runtime, context.allocator)
	cfg := exec.default_config()
	cfg.workers          = WORKERS
	cfg.mailbox_capacity = CAPACITY
	cfg.batch            = 16
	cfg.seed             = seed
	cfg.handler          = handler
	cfg.io_handler       = io_handler

	start := time.tick_now()
	if !exec.start(rt, cfg, u64(TOTAL), context.allocator) {
		fail("exec.start failed")
	}

	// The only external stimulus: one real write per worker. Everything after this is kernel
	// readiness -> event loop -> SPSC, with no controller-side message injection.
	trigger: [8]u8
	for i in 0..<WORKERS {
		for j in 0..<8 {
			trigger[j] = u8(i + 1)
		}
		if io.write_fd(PIPES[i][1], trigger[:]) != 8 {
			fail("trigger write to worker %d failed", i)
		}
	}

	// Bounded wait: if the I/O source is broken this fails in 5 s instead of hanging CI.
	deadline := time.tick_now()
	for sync.atomic_load_explicit(&rt.consumed, .Acquire) < u64(TOTAL) {
		if time.tick_since(deadline) > 5_000_000_000 {
			fail("timed out waiting for I/O-driven deliveries (consumed %d of %d)",
				sync.atomic_load_explicit(&rt.consumed, .Acquire), u64(TOTAL))
		}
		sync.cpu_relax()
	}
	exec.stop(rt, context.allocator)
	elapsed := time.tick_since(start)

	// --- global counters -------------------------------------------------------------------
	if sync.atomic_load_explicit(&rt.consumed, .Acquire) != u64(TOTAL) {
		fail("consumed %d, want %d", rt.consumed, u64(TOTAL))
	}
	if sync.atomic_load_explicit(&rt.sent, .Acquire) != u64(TOTAL) {
		fail("sent %d, want %d", rt.sent, u64(TOTAL))
	}
	if sync.atomic_load_explicit(&rt.dropped, .Relaxed) != 0 {
		fail("a send was dropped on a bounded-but-retried channel")
	}
	if sync.atomic_load_explicit(&g_io_bad, .Relaxed) != 0 {
		fail("%d real I/O completions were malformed or failed to seed", g_io_bad)
	}
	if exec.total_bad(rt) != 0 {
		fail("%d per-worker cache round trips failed", exec.total_bad(rt))
	}
	if rt.log_records != u64(2 * WORKERS) {
		fail("log drained %d records, want %d", rt.log_records, 2 * WORKERS)
	}

	// --- per-worker state ------------------------------------------------------------------
	want_sum := u64(TOTAL) * u64(TOTAL - 1) / 2
	got_sum: u64 = 0
	got_handled: u64 = 0
	blocked_total: u64 = 0
	pumped_total: u64 = 0
	pump_rounds: u64 = 0
	for i in 0..<WORKERS {
		got_sum += exec.worker_sum(rt, i)
		got_handled += exec.worker_handled(rt, i)
		s := rt.stats[i]
		blocked_total += s.blocked
		pumped_total  += s.pumped
		pump_rounds   += s.pump_rounds
		if s.posted != 0 {
			fail("worker %d has %d unhandled events", i, s.posted)
		}
		if s.ticks == 0 {
			fail("worker %d never ticked its own event loop", i)
		}
		if s.io_completions == 0 {
			fail("worker %d never received a real kernel completion", i)
		}
		if s.stopped != 1 {
			fail("worker %d never acknowledged the stop flag", i)
		}
	}
	if got_sum != want_sum || got_handled != u64(TOTAL) {
		fail("I/O-driven litmus: sum %d (want %d), handled %d (want %d)",
			got_sum, want_sum, got_handled, u64(TOTAL))
	}
	// The backpressure path must actually have run. If the batch somehow completed without a
	// single full channel, this test would not be testing forward progress at all.
	if blocked_total == 0 || pumped_total == 0 || pump_rounds == 0 {
		fail("backpressure not exercised: %d blocked pushes, %d pump rounds, %d pumped",
			blocked_total, pump_rounds, pumped_total)
	}
	if pumped_total > u64(TOTAL) {
		fail("pump consumed %d envelopes, more than the %d delivered", pumped_total, u64(TOTAL))
	}

	// --- supervision policy over the same workers -------------------------------------------
	restarted: [supervise.MAX_CHILDREN]supervise.Handle
	a1, c1 := exec.report_failure(rt, 0, 10, restarted[:])
	if a1 != .Restart || c1 != WORKERS {
		fail("One_For_All: action %v count %d, want Restart/%d", a1, c1, WORKERS)
	}
	if supervise.resolve(&rt.group, rt.handles[0]) != -1 {
		fail("a handle from before the group restart still resolves")
	}
	a2, _ := exec.report_failure(rt, 0, 20, restarted[:])
	if a2 != .Restart {
		fail("second failure inside the window should still restart")
	}
	a3, c3 := exec.report_failure(rt, 0, 30, restarted[:])
	if a3 != .Give_Up || c3 != 0 || rt.group.escalations != 1 {
		fail("restart window did not escalate after the limit")
	}
	a4, _ := exec.report_failure(rt, 0, 200, restarted[:])
	if a4 != .Restart {
		fail("restart window did not reset after it expired")
	}

	for i in 0..<WORKERS {
		io.close_fd(PIPES[i][0])
		io.close_fd(PIPES[i][1])
	}

	us := time.duration_microseconds(elapsed)
	rate := f64(TOTAL) * 1e6 / us
	fmt.printf("  exec: %d workers, %d SPSC channels (capacity %d < burst %d), %d I/O-driven deliveries in %.0f us (%.0f msg/s), no loss/duplication\n",
		WORKERS, WORKERS * WORKERS, CAPACITY, PER_PAIR, TOTAL, us, rate)
	fmt.printf("  exec: %d full-channel pushes resolved by %d pump rounds consuming %d envelopes\n",
		blocked_total, pump_rounds, pumped_total)
	fmt.println("exec thread-per-core tests: ok")
}
