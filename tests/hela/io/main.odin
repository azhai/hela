#+dialect hela

// End-to-end regression for `core:hela/io`, the real kernel event source.
//
// This one deliberately uses a REAL pipe and a REAL kqueue/poll wait: no simulated event, no
// injected completion. The interesting assertions are not "a notification arrived" but:
//
//   * the 32-byte `Completion` wire format is locked at compile time (bytes, padding, cache line);
//   * `io.poll` only *publishes* events -- the handler must NOT have run before `loop_tick`;
//     that is what keeps the deterministic event loop deterministic once the OS is involved;
//   * the `Completion -> Event -> Completion` projection round-trips fd, tag, kind and byte count;
//   * deregistering actually stops notifications, and EOF is surfaced as a declared flag;
//   * nothing was dropped (`Source.errors == 0`) and the loop is idle at the end.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"

import "core:hela/event"
import io "core:hela/io"

TAG :: u16(0xBEEF)

// ---------------------------------------------------------------------------------------------
// 1. Layout: the OS event wire format and the per-thread source
// ---------------------------------------------------------------------------------------------

#assert(size_of(io.Completion) == io.COMPLETION_SIZE)
#assert(offset_of_by_string(io.Completion, "kind") == 0)
#assert(offset_of_by_string(io.Completion, "bytes") == 8)
#assert(offset_of_by_string(io.Completion, "udata") == 16)
#assert(offset_of_by_string(io.Completion, "seq") == 28)
#assert(intrinsics.layout_padding_of(io.Completion) == 0)
#assert(intrinsics.layout_cache_lines_of(io.Completion) == 1)

#assert(size_of(io.Fd_Entry) == 8)
#assert(size_of(io.Source) % io.Cache_Line == 0)
#assert(offset_of_by_string(io.Source, "entries") == io.Cache_Line)

// ---------------------------------------------------------------------------------------------
// 2. Handler state. `event.Handler` has no user-data parameter, so a single-threaded test uses
//    package-level state. That is fine: this test proves the dispatch *order*, not concurrency.
// ---------------------------------------------------------------------------------------------

g_handled: int
g_last:    io.Completion
g_read:    [8]u8
g_read_n:  int
g_bad:     int

fixed_clock :: proc() -> i64 {
	return 0
}

io_handler :: proc(l: ^event.Loop, e: event.Event) {
	l.posted -= 1
	g_handled += 1
	if e.kind != io.EVENT_IO {
		g_bad += 1
		return
	}
	c := io.event_to_completion(e)
	g_last   = c
	g_read_n = io.read_fd(i32(c.handle), g_read[:])
}

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

main :: proc() {
	if !io.FULLY_SUPPORTED {
		fmt.println("io event source tests: skipped (no backend on this target)")
		return
	}

	payload := [8]u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
	r, w, ok := io.make_pipe()
	if !ok {
		fail("make_pipe failed (errno %d)", io.os_errno())
	}

	s: io.Source
	if !io.source_init(&s) {
		fail("source_init failed")
	}
	if !io.add(&s, r, TAG, io.WANT_READ) {
		fail("add(read fd) failed")
	}

	loop: event.Loop
	if !event.loop_init(&loop, 64, fixed_clock, io_handler, context.allocator) {
		fail("loop_init failed")
	}

	// Round 1: a real write, a real kernel wait, a deterministic dispatch.
	if io.write_fd(w, payload[:]) != len(payload) {
		fail("write_fd wrote the wrong number of bytes")
	}
	posted := io.poll(&s, &loop, 0)
	if posted != 1 {
		fail("poll posted %d completions, expected 1", posted)
	}
	if g_handled != 0 {
		fail("the handler ran during poll; dispatch must happen only inside loop_tick")
	}
	if event.loop_tick(&loop, 16) < 1 {
		fail("loop_tick dispatched nothing")
	}
	if g_handled != 1 || g_bad != 0 {
		fail("handler count %d, bad %d", g_handled, g_bad)
	}

	c := g_last
	if c.kind != .Read || c.handle != u32(r) || c.tag != TAG || c.udata != u64(TAG) {
		fail("projection lost identity: kind=%v handle=%d tag=%d udata=%d",
			c.kind, c.handle, c.tag, c.udata)
	}
	if c.bytes != 8 || c.errno != 0 || c.flags != 0 {
		fail("projection lost shape: bytes=%d errno=%d flags=%d", c.bytes, c.errno, c.flags)
	}
	// `seq` is intentionally NOT projected into `Event`: it is a property of the collection, not
	// of the notification. Read the full record from `Source.batch` instead.
	if g_last.seq != 0 {
		fail("seq unexpectedly survived the projection")
	}
	seq1 := s.batch[0].seq
	if g_read_n != len(payload) {
		fail("read_fd got %d bytes, expected %d", g_read_n, len(payload))
	}
	for i in 0..<len(payload) {
		if g_read[i] != payload[i] {
			fail("byte %d of the real pipe payload differs", i)
		}
	}

	// Round 2: a second notification, with a fresh sequence number.
	payload2 := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	if io.write_fd(w, payload2[:]) != len(payload2) {
		fail("second write_fd failed")
	}
	if io.poll(&s, &loop, 0) != 1 {
		fail("second poll did not report one completion")
	}
	if event.loop_tick(&loop, 16) < 1 || g_handled != 2 {
		fail("second dispatch did not reach the handler")
	}
	if s.batch[0].seq != seq1 + 1 {
		fail("collection sequence did not advance: %d -> %d", seq1, s.batch[0].seq)
	}

	// Deregistration must actually stop the kernel from reporting this fd.
	if !io.remove(&s, r) {
		fail("remove(read fd) failed")
	}
	if io.write_fd(w, payload[:]) != len(payload) {
		fail("write after remove failed")
	}
	if io.poll(&s, &loop, 0) != 0 {
		fail("a deregistered fd still produced a completion")
	}

	// EOF: closing the write end must surface as a declared flag, not a silent zero-byte event.
	if !io.add(&s, r, TAG, io.WANT_READ) {
		fail("re-add(read fd) failed")
	}
	io.close_fd(w)
	w = -1
	if io.poll(&s, &loop, 10) != 1 {
		fail("EOF was not reported by the kernel")
	}
	if event.loop_tick(&loop, 16) < 1 {
		fail("EOF event was not dispatched")
	}
	if g_last.flags & io.FLAG_EOF == 0 {
		fail("EOF completion lacks FLAG_EOF (flags=%d)", g_last.flags)
	}

	if io.source_errors(&s) != 0 {
		fail("poll dropped %d completions", io.source_errors(&s))
	}
	if io.source_completions(&s) != 3 {
		fail("expected 3 completions, got %d", io.source_completions(&s))
	}
	if !event.is_idle(&loop) || loop.posted != 0 {
		fail("the event loop is not idle after dispatch")
	}

	fmt.printf("io event source: %d real kernel completions, %d polls, no drops\n",
		io.source_completions(&s), io.source_polls(&s))
	fmt.println("io event source tests: ok")

	io.source_destroy(&s)
	event.loop_destroy(&loop, context.allocator)
	io.close_fd(r)
}
