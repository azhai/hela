#+dialect hela
#+analysis alloc

// Supervision (督程): restart policy over generational handles. Pure integers, no threads, no
// signals, no hidden state — which is exactly why the decision is deterministic and testable.
//
// tina's supervision catches SIGSEGV with an OS trap boundary and restarts an Isolate. Hela does
// not port the trap machinery (it needs platform signal handling and thread_local state, neither
// of which is visible in a layout manifest). What is portable and worth keeping is the *policy*:
// a group of children, a restart strategy, and a sliding window that escalates when a child
// crashes too often. `report_failure` is that policy as a pure function of (handle, now).
package supervise

MAX_CHILDREN :: 32

Strategy :: enum u8 {
	One_For_One,  // restart only the failed child
	One_For_All,  // restart every child in the group
	Rest_For_One, // restart the failed child and every child started after it
}

Action :: enum u8 {
	Restart,
	Give_Up,
}

// Handle packs generation in the high 32 bits and slot index in the low 32. A handle from before
// a restart never resolves again: the generation check rejects it. This is the same encoding tina
// uses for Isolate_Handle, minus the shard/type bits a single-process group does not need.
Handle :: distinct u64
HANDLE_NONE :: Handle(0)

handle_index      :: proc(h: Handle) -> int {return int(u64(h) & 0xFFFFFFFF)}
handle_generation :: proc(h: Handle) -> u32 {return u32(u64(h) >> 32)}
make_handle       :: proc(index: int, generation: u32) -> Handle {
	return Handle(u64(generation) << 32 | u64(index))
}

Child :: struct {
	name:       string,
	handle:     Handle,
	restarts:   u32,
	generation: u32,
}

Group :: struct {
	children:           [MAX_CHILDREN]Child,
	count:              int,
	strategy:           Strategy,
	max_restarts:       int,
	window:             i64,
	window_start:       i64,
	restarts_in_window: int,
	total_restarts:     u64,
	escalations:        u64,
	stale_reports:      u64,
}

group_init :: proc(g: ^Group, strategy: Strategy, max_restarts: int, window: i64) {
	g.strategy     = strategy
	g.max_restarts = max_restarts
	g.window       = window
}

// group_add starts a child with generation 1. Names are for humans; handles are for the runtime.
group_add :: proc(g: ^Group, name: string) -> (h: Handle, ok: bool) {
	if g.count >= MAX_CHILDREN {
		return HANDLE_NONE, false
	}
	index := g.count
	g.count += 1
	g.children[index] = Child{name = name, generation = 1}
	g.children[index].handle = make_handle(index, 1)
	return g.children[index].handle, true
}

group_find :: proc(g: ^Group, name: string) -> Handle {
	for i in 0..<g.count {
		if g.children[i].name == name {
			return g.children[i].handle
		}
	}
	return HANDLE_NONE
}

// resolve rejects stale handles. It is the whole reason for the generation bits: a crash report
// that arrives late must not restart a child that has already been recreated.
resolve :: proc(g: ^Group, h: Handle) -> int {
	index := handle_index(h)
	if index < 0 || index >= g.count || handle_generation(h) == 0 {
		return -1
	}
	if g.children[index].generation != handle_generation(h) {
		return -1
	}
	if g.children[index].handle != h {
		return -1
	}
	return index
}

// report_failure applies the sliding window and the group strategy. `restarted` receives the NEW
// handles of the children that must be started again, in group order. Nothing is restarted by
// this function itself: it is a decision, and the caller owns the side effect.
report_failure :: proc(g: ^Group, h: Handle, now: i64, restarted: []Handle) -> (action: Action, count: int) {
	index := resolve(g, h)
	if index < 0 {
		g.stale_reports += 1
		return .Give_Up, 0
	}
	if g.window > 0 && now - g.window_start > g.window {
		g.window_start = now
		g.restarts_in_window = 0
	}
	if g.max_restarts > 0 && g.restarts_in_window >= g.max_restarts {
		g.escalations += 1
		return .Give_Up, 0
	}
	g.restarts_in_window += 1

	first := 0
	last  := g.count - 1
	switch g.strategy {
	case .One_For_One:
		first = index
		last  = index
	case .One_For_All:
		first = 0
		last  = g.count - 1
	case .Rest_For_One:
		first = index
		last  = g.count - 1
	}

	count = 0
	for i in first..=last {
		child := &g.children[i]
		gen := child.generation + 1
		if gen == 0 {
			gen = 1
		}
		child.generation = gen
		child.handle = make_handle(i, gen)
		child.restarts += 1
		g.total_restarts += 1
		if count < len(restarted) {
			restarted[count] = child.handle
		}
		count += 1
	}
	return .Restart, count
}
