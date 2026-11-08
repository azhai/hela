#+dialect hela
#+analysis alloc
#+analysis sharing

// Real I/O event source for Hela.
//
// Until now `core:hela/event` only produced events itself (a user `post`, or a timer from an
// injected clock). Nothing in the loop came from the kernel. This package closes that gap, but
// deliberately does NOT add another reactor: the platform multiplexer stays in `core:sys/kqueue`
// / `core:sys/posix/poll` (upstream already owns those bindings), and the Hela side does only the
// three things a layout-oriented dialect is supposed to do:
//
//   1. Normalize every OS readiness notification into ONE fixed byte shape, `Completion`.
//      Its bytes are declared with `#explicit` + `#offset`, locked by `#assert`, exported by
//      `-emit-layout`, and therefore readable by an AI without knowing what a `struct kevent` is.
//   2. Publish those completions through `event.post` instead of invoking user code. The user
//      handler still runs only inside `event.loop_tick`, so the DST invariant survives real I/O.
//   3. Declare who owns the poller. One `Source` per thread (one kqueue fd per core in `exec`):
//      no shared poller descriptor, and `--contract` can show the ownership.
//
// `Completion` -> `event.Event` is a lossy projection into the 5 fields `Event` already has;
// `event_to_completion` is the exact inverse for everything it projects. `seq` is the one field
// that is not projected: `Source.completions` is the global sequence, so a handler can recover
// ordering without carrying it in the event. Saying that out loud is the point of this package.
package hela_io

import "base:intrinsics"

import "core:sync"

import "core:hela/event"

Cache_Line      :: 64
MAX_FDS         :: 32
MAX_EVENTS      :: 32
COMPLETION_SIZE :: 32

// `event` owns kind 0 (USER) and 1 (TIMER) and is otherwise a pure dispatcher. kind is an open
// namespace: an I/O source claims 2 here rather than making `event` depend on the OS.
EVENT_IO :: 2

Kind :: enum u8 {
	Read,
	Write,
	Timer,
	User,
	Error,
}

FLAG_EOF   :: u8(1) << 0
FLAG_ERROR :: u8(1) << 1
FLAG_HUP   :: u8(1) << 2
FLAG_EDGE  :: u8(1) << 3

WANT_READ  :: u8(1) << 0
WANT_WRITE :: u8(1) << 1

// One OS readiness notification, normalized. kqueue's `KEvent` and POSIX `pollfd` have different
// shapes on different targets; this one does not. Every byte is named, so there is no implicit
// padding and the manifest is a wire-format spec, not a guess.
Completion :: struct #explicit {
	#offset(0)  kind:   Kind,  // which filter fired
	#offset(1)  flags:  u8,    // FLAG_EOF / FLAG_ERROR / FLAG_HUP / FLAG_EDGE
	#offset(2)  tag:    u16,   // caller-owned correlation, survives the kernel round trip
	#offset(4)  handle: u32,   // the fd
	#offset(8)  bytes:  i64,   // kqueue: available bytes; poll: 0 (unknown, never guessed)
	#offset(16) udata:  u64,   // opaque kernel passthrough (kqueue udata / poll tag)
	#offset(24) errno:  i32,   // 0 on success
	#offset(28) seq:    u32,   // collection sequence within this Source's lifetime
}

#assert(size_of(Completion) == COMPLETION_SIZE)
#assert(offset_of_by_string(Completion, "kind") == 0)
#assert(offset_of_by_string(Completion, "bytes") == 8)
#assert(offset_of_by_string(Completion, "udata") == 16)
#assert(offset_of_by_string(Completion, "seq") == 28)
#assert(intrinsics.layout_padding_of(Completion) == 0)
#assert(intrinsics.layout_cache_lines_of(Completion) == 1)

Fd_Entry :: struct {
	fd:   i32,
	tag:  u16,
	want: u8,
	used: u8,
}

#assert(size_of(Fd_Entry) == 8)

// Source is per-thread state. `#align` puts the ownership counters and the registration table on
// separate lines; `#atomic` + `#share(owner)` say that only this thread's loop writes them. The
// tables are inline: one boot-time setup, zero allocation while polling, and the byte budget is
// visible in the layout manifest.
Source :: struct {
	#align(Cache_Line) #atomic #share(owner) polled: u64,
	#atomic #share(owner) completions: u64,
	#atomic #share(owner) errors: u64,
	#align(Cache_Line) entries: [MAX_FDS]Fd_Entry,
	count: int,
	kq: i32, // backend descriptor; -1 when the backend is not available
	ready: int,
	batch: [MAX_EVENTS]Completion,
}

#assert(align_of(Source) == Cache_Line)
#assert(offset_of_by_string(Source, "entries") == Cache_Line)
#assert(size_of(Source) % Cache_Line == 0)

// The projection: `arg1` packs handle(32) | kind(8) | flags(8) | errno(16). `arg0` carries the
// byte count, `id` the opaque udata, `tag` the caller correlation. Nothing else is invented.
completion_to_event :: proc(c: Completion) -> event.Event {
	packed := u64(c.handle) | (u64(c.kind) << 32) | (u64(c.flags) << 40) | (u64(u32(c.errno)) << 48)
	return event.Event{
		kind = EVENT_IO,
		tag  = c.tag,
		id   = c.udata,
		arg0 = c.bytes,
		arg1 = i64(packed),
	}
}

event_to_completion :: proc(e: event.Event) -> Completion {
	packed := u64(e.arg1)
	return Completion{
		kind   = Kind(u8(packed >> 32)),
		flags  = u8(packed >> 40),
		tag    = e.tag,
		handle = u32(packed),
		bytes  = e.arg0,
		udata  = e.id,
		errno  = i32(u16(packed >> 48)),
		seq    = 0, // not projected; `Source.completions` is the global sequence
	}
}

source_init :: proc(s: ^Source) -> bool {
	s.count = 0
	s.kq    = -1
	s.ready = 0
	sync.atomic_store_explicit(&s.polled, 0, .Relaxed)
	sync.atomic_store_explicit(&s.completions, 0, .Relaxed)
	sync.atomic_store_explicit(&s.errors, 0, .Relaxed)
	for i in 0..<MAX_FDS {
		s.entries[i] = {}
	}
	return _backend_init(s)
}

source_destroy :: proc(s: ^Source) {
	_backend_destroy(s)
	s.count = 0
	s.kq    = -1
	s.ready = 0
}

// add registers one fd. `tag` is passed through the kernel unchanged, so the handler can tell
// two descriptors apart without a lookup. Registration is a boot-time operation: a Source is
// owned by exactly one thread.
add :: proc(s: ^Source, fd: i32, tag: u16, want: u8) -> bool {
	if fd < 0 || s.count >= MAX_FDS || want == 0 {
		return false
	}
	e := Fd_Entry{fd = fd, tag = tag, want = want, used = 1}
	if !_backend_add(s, e) {
		return false
	}
	s.entries[s.count] = e
	s.count += 1
	return true
}

remove :: proc(s: ^Source, fd: i32) -> bool {
	idx := -1
	for i in 0..<s.count {
		if s.entries[i].fd == fd {
			idx = i
			break
		}
	}
	if idx < 0 {
		return false
	}
	e := s.entries[idx]
	if !_backend_remove(s, e) {
		return false
	}
	s.count -= 1
	if idx != s.count {
		s.entries[idx] = s.entries[s.count]
	}
	s.entries[s.count] = {}
	return true
}

// poll collects one batch of OS readiness notifications, normalizes them into `s.batch`, and
// publishes them as events. It NEVER calls a user handler: dispatch happens in `event.loop_tick`.
// A full event queue is reported through `Source.errors` rather than silently dropping a
// completion -- a dropped kernel notification is exactly the kind of hidden behaviour Hela exists
// to make visible.
poll :: proc(s: ^Source, l: ^event.Loop, timeout_ms := 0) -> int {
	n := _backend_wait(s, timeout_ms)
	sync.atomic_add_explicit(&s.polled, 1, .Relaxed)
	base := sync.atomic_load_explicit(&s.completions, .Relaxed)
	for i in 0..<n {
		s.batch[i].seq = u32(base + u64(i))
	}
	posted := 0
	for i in 0..<n {
		if !event.post(l, completion_to_event(s.batch[i])) {
			missed := n - i
			for _ in 0..<missed {
				sync.atomic_add_explicit(&s.errors, 1, .Relaxed)
			}
			break
		}
		posted += 1
		sync.atomic_add_explicit(&s.completions, 1, .Relaxed)
	}
	return posted
}

source_polls :: proc(s: ^Source) -> u64 {
	return sync.atomic_load_explicit(&s.polled, .Relaxed)
}

source_completions :: proc(s: ^Source) -> u64 {
	return sync.atomic_load_explicit(&s.completions, .Relaxed)
}

source_errors :: proc(s: ^Source) -> u64 {
	return sync.atomic_load_explicit(&s.errors, .Relaxed)
}
