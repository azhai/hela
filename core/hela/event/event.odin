#+dialect hela
#+analysis alloc
#+analysis sharing

// Event loop: a bounded event queue, a fixed timer wheel, and an injectable clock.
//
// The point of this package is *determinism*, not I/O. `Clock` is a function pointer: in
// production it reads a monotonic counter, in a simulation it returns a counter the test owns.
// `loop_tick` is one round — drain at most `budget` events, then advance timers to `clock()`.
// Same sequence of posts + same clock values = same order of handler calls, every time. This is
// the smallest useful subset of tina's DST; no OS trap, no thread_local, no platform backend.
package event

import "core:time"

import "core:hela/queue"

MAX_TIMERS :: 64
Cache_Line :: 64

// A slot's `bitmap` bit is the only piece of shared state: one atomic word, one cache line.
// Deadlines/ids/tags live in parallel arrays (the SoA shape tina's timer wheel uses), so scanning
// due timers touches only the arrays it needs.
Wheel :: struct {
	#align(Cache_Line) #atomic #share(scheduler) bitmap: u64,
	deadlines: [MAX_TIMERS]i64,
	ids:       [MAX_TIMERS]u64,
	tags:      [MAX_TIMERS]u16,
	last_now:  i64,
}

wheel_init :: proc(w: ^Wheel) {
	w.bitmap   = 0
	w.last_now = 0
}

// wheel_arm returns the slot number, or -1 when the wheel is full. Generation-free on purpose:
// a timer is identified by its `id`, and the caller owns the id space.
wheel_arm :: proc(w: ^Wheel, id: u64, deadline: i64, tag: u16) -> int {
	free := -1
	for i in 0..<MAX_TIMERS {
		if w.bitmap & (u64(1) << u64(i)) == 0 {
			free = i
			break
		}
	}
	if free < 0 {
		return -1
	}
	w.deadlines[free] = deadline
	w.ids[free]       = id
	w.tags[free]      = tag
	w.bitmap |= u64(1) << u64(free)
	return free
}

wheel_cancel :: proc(w: ^Wheel, slot: int) -> bool {
	if slot < 0 || slot >= MAX_TIMERS {
		return false
	}
	bit := u64(1) << u64(slot)
	if w.bitmap & bit == 0 {
		return false
	}
	w.bitmap &= ~bit
	return true
}

// wheel_expire collects every timer due at `now` and clears its bit in one pass. Clearing before
// the caller runs handlers means a handler can arm a new timer and reuse the slot immediately.
wheel_expire :: proc(w: ^Wheel, now: i64, ids: []u64, tags: []u16) -> int {
	w.last_now = now
	fired := 0
	for i in 0..<MAX_TIMERS {
		bit := u64(1) << u64(i)
		if w.bitmap & bit == 0 {
			continue
		}
		if w.deadlines[i] > now {
			continue
		}
		if fired < len(ids) {
			ids[fired] = w.ids[i]
			tags[fired] = w.tags[i]
		}
		w.bitmap &= ~bit
		fired += 1
	}
	return fired
}

wheel_pending :: proc(w: ^Wheel) -> int {
	count := 0
	for i in 0..<MAX_TIMERS {
		if w.bitmap & (u64(1) << u64(i)) != 0 {
			count += 1
		}
	}
	return count
}

Clock   :: #type proc() -> i64
Handler :: #type proc(^Loop, Event)

Event :: struct {
	kind: u16,
	tag:  u16,
	id:   u64,
	arg0: i64,
	arg1: i64,
}

EVENT_USER :: 0
EVENT_TIMER :: 1

Loop :: struct {
	q:       queue.Queue(Event),
	wheel:   Wheel,
	clock:   Clock,
	handler: Handler,
	// Caller-owned context, reachable from the handler without a global. An I/O source posts
	// completions into this loop, so its handler needs to know which worker/connection it belongs
	// to. `loop_init` clears it; the owner sets it once, before the loop starts.
	user:    rawptr,
	ticks:   u64,
	fired:   u64,
	posted:  u64,
}

// wall_clock is a monotonic nanosecond counter. It is a *default*, not a hidden dependency: the
// caller can pass a deterministic clock instead.
wall_clock :: proc() -> i64 {
	return i64(time.tick_since(time.Tick{}))
}

loop_init :: proc(l: ^Loop, capacity: int, clock: Clock, handler: Handler, allocator := context.allocator) -> bool {
	if !queue.init(&l.q, capacity, allocator) {
		return false
	}
	wheel_init(&l.wheel)
	if clock != nil {
		l.clock = clock
	} else {
		l.clock = wall_clock
	}
	l.handler = handler
	l.user    = nil
	return true
}

loop_destroy :: proc(l: ^Loop, allocator := context.allocator) {
	queue.destroy(&l.q, allocator)
}

post :: proc(l: ^Loop, e: Event) -> bool {
	if !queue.push(&l.q, e) {
		return false
	}
	l.posted += 1
	return true
}

// post_timer arms a timer; when it fires, a TIMER event is queued so the handler sees it in the
// same deterministic order as any other event.
post_timer :: proc(l: ^Loop, id: u64, deadline: i64, tag: u16) -> bool {
	return wheel_arm(&l.wheel, id, deadline, tag) >= 0
}

// loop_tick is one round: at most `budget` queued events, then all timers due at `clock()`.
loop_tick :: proc(l: ^Loop, budget: int) -> int {
	now := l.clock()
	handled := 0
	for handled < budget {
		e, ok := queue.pop(&l.q)
		if !ok {
			break
		}
		if l.handler != nil {
			l.handler(l, e)
		}
		handled += 1
	}
	// A timer completion is an event, not a direct callback into user code: that keeps the
	// "handler only runs inside loop_tick" invariant which is what makes simulation reproducible.
	due_ids:  [MAX_TIMERS]u64
	due_tags: [MAX_TIMERS]u16
	fired := wheel_expire(&l.wheel, now, due_ids[:], due_tags[:])
	l.fired += u64(fired)
	for i in 0..<fired {
		e := Event{kind = EVENT_TIMER, tag = due_tags[i], id = due_ids[i]}
		if queue.push(&l.q, e) {
			l.posted += 1
		}
	}
	l.ticks += 1
	return handled + fired
}

// is_idle is the DST "globally idle" predicate: nothing queued, nothing armed.
is_idle :: proc(l: ^Loop) -> bool {
	return queue.length(&l.q) == 0 && wheel_pending(&l.wheel) == 0
}
