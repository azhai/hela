#+dialect hela
#+analysis alloc
#+analysis sharing

// core:hela/flow — reusable backpressure for bounded SPSC topologies.
//
// A bounded ring is only correct if somebody drains it. The failure mode is not a data race and
// not a wrong offset; it is a *liveness* bug that no layout manifest can see:
//
//   N workers each seed their outbound channels before anybody enters a drain loop.
//   Every channel fills; every worker spins inside push; nobody consumes. Deadlock.
//
// M19 worked around this with a declared work budget (capacity >= per-channel burst). That is a
// real constraint, not a solution: an unbounded stream cannot promise its batch size up front.
// This package makes the backpressure state a declared, reusable data structure instead of an
// invisible spin loop, and turns "what do I do when the channel is full?" into a pure, exhaustively
// testable decision.
//
// Three policies, one shape:
//
//   .Spin    retry forever. Only sound if an external drainer is guaranteed (M19's budget).
//   .Pump    while blocked, drain YOUR OWN inbox. In an N x N matrix that frees the channels
//            other producers are blocked on, so the system makes forward progress.
//   .Reject  return immediately; the caller decides to retry, drop or buffer.
//
// `Gate` is worker-local (no atomics needed), but gets its own cache line because it lives next to
// shared runtime state. `Table($N)` is one gate per worker, 64 B apart, so `--contract` can name
// the owner of every line. This mirrors `core:hela/pattern`'s `Table($N)`: one read-mostly table
// built once, one state table owned by exactly one thread each.
//
// Re-entrancy is the whole trick. A user handler may itself call `send`; if `send` pumps while a
// handler is running it would re-enter the handler and overwrite the shared drain buffer. `depth`
// makes `on_full` fall back to `.Retry` inside a handler. That is a weaker guarantee (an external
// drainer is needed again in that narrow window), so it is documented rather than hidden.
package flow

import "base:intrinsics"
import "core:sync"

Cache_Line :: 64
MAX_N      :: 8

Policy :: enum u8 {
	Spin,   // retry forever, requires an external consumer
	Pump,   // drain your own inbox while blocked
	Reject, // give up immediately, caller decides
}

Action :: enum u8 {
	Retry, // try the push again
	Drain, // consume your own inbox, then retry
	Abort, // the push did not happen
}

// One worker's backpressure state. 64 B, no padding, one owner per line. Every byte is named so
// `-emit-layout` can show the whole contract and `layout_padding_of` stays zero.
Gate :: struct #explicit #align(Cache_Line) {
	#share(worker) blocked:   u64, // times a push found the channel full
	#share(worker) drains:    u64, // pump rounds actually entered
	#share(worker) delivered: u64, // envelopes consumed by those pump rounds
	#share(worker) spins:     u64, // retries without a pump (re-entrant or nothing to drain)
	#share(worker) depth:     u32, // > 0 while a user handler is running
	#share(worker) policy:    u8,
	_:                        [3]u8,
	reserved:                 [24]u8, // room for future counters without moving any byte
}

#assert(size_of(Gate) == Cache_Line)
#assert(align_of(Gate) == Cache_Line)
#assert(intrinsics.layout_padding_of(Gate) == 0)
#assert(offset_of_by_string(Gate, "depth") == 32)

// Table is the reusable shape: one gate per worker, each on its own line, no indirection.
Table :: struct($N: int) #explicit {
	gates: [N]Gate,
}

// A concrete instantiation, so `-emit-layout` exports the table's bytes (a bare polymorphic
// `Table($N)` has no manifest entry). Same trick as `core:hela/pattern`'s `Table_4`.
Table_8 :: Table(MAX_N)

#assert(size_of(Table_8) == MAX_N * Cache_Line)
#assert(align_of(Table_8) == Cache_Line)
#assert(intrinsics.layout_padding_of(Table_8) == 0)

gate_init :: proc(g: ^Gate, p: Policy) {
	g^ = Gate{policy = u8(p)}
}

table_init :: proc(t: ^Table($N), p: Policy) {
	for i in 0..<N {
		gate_init(&t.gates[i], p)
	}
}

enter :: proc(g: ^Gate) {
	g.depth += 1
}

leave :: proc(g: ^Gate) {
	if g.depth != 0 {
		g.depth -= 1
	}
}

// plan is the entire policy, as a pure function of (policy, re-entrancy depth). Keeping it free
// of Gate state means the truth table can be checked exhaustively without threads.
plan :: proc(p: Policy, depth: u32) -> Action {
	switch p {
	case .Spin:
		return .Retry
	case .Reject:
		return .Abort
	case .Pump:
		if depth != 0 {
			return .Retry // pumping here would re-enter the user handler
		}
		return .Drain
	}
	return .Retry
}

// on_full records the stall and returns the next action. Called only on the slow path: a push that
// succeeds on the first try never touches a Gate.
on_full :: proc(g: ^Gate) -> Action {
	g.blocked += 1
	return plan(Policy(g.policy), g.depth)
}

note_drain :: proc(g: ^Gate, n: int) {
	g.drains += 1
	if n > 0 {
		g.delivered += u64(n)
	}
}

note_spin :: proc(g: ^Gate) {
	g.spins += 1
}

// spin_hint keeps `core:sync` anchored for -vet-unused and gives callers a portable backoff.
spin_hint :: proc() {
	sync.cpu_relax()
}

// simulate is a deterministic, thread-free model of the classic "everyone seeds before anyone
// drains" topology. N workers each owe `burst` pushes into every one of the N channels (including
// their own); each channel holds `capacity` unconsumed envelopes.
//
// Two phases per round, mirroring a real worker:
//   1. seeding — a worker that has not finished its promises pushes until it blocks; a full
//      channel is handled strictly according to the policy. There is NO implicit drainer.
//   2. running — a worker whose seed returned enters its main loop and unconditionally drains
//      its own inbox every round. This phase is what makes the model honest: with `.Spin`, NO
//      worker ever reaches it, because everybody is stuck in phase 1.
//
// Returns whether every promised push was made AND every in-flight envelope consumed, how many
// rounds it took, and how many pump rounds were entered. `.Spin` reports the deadlock instead of
// hanging the test process; `.Pump` reaches phase 2 and finishes. This is a model, not proof of
// the runtime: the real evidence is `tests/hela/exec` with a capacity far below its burst, under
// TSAN.
simulate :: proc(p: Policy, n: int, capacity: int, burst: int, max_rounds: int) -> (done: bool, rounds: int, drains: int) {
	if n <= 0 || n > MAX_N || capacity <= 0 || burst < 0 || max_rounds <= 0 {
		return false, 0, 0
	}
	pending:   [MAX_N][MAX_N]int
	inflight:  [MAX_N][MAX_N]int
	seeded:    [MAX_N]bool
	remaining: int = 0
	for s in 0..<n {
		for d in 0..<n {
			pending[s][d] = burst
			remaining += burst
		}
	}
	if remaining == 0 {
		return true, 0, 0
	}

	for round in 1..=max_rounds {
		progressed := false

		// Phase 1: seeding. One worker's turn pushes as far as it can, then yields.
		for s in 0..<n {
			if seeded[s] {
				continue
			}
			for d in 0..<n {
				for pending[s][d] > 0 {
					if inflight[s][d] < capacity {
						inflight[s][d] += 1
						pending[s][d] -= 1
						remaining -= 1
						progressed = true
						continue
					}
					if plan(p, 0) != .Drain {
						break // full and no permission to pump: this worker is stuck in its seed
					}
					// Pump: consume everything addressed to this worker. Those envelopes were
					// produced by other workers, so this frees their outbound channels.
					freed := 0
					for src in 0..<n {
						freed += inflight[src][s]
						inflight[src][s] = 0
					}
					if freed == 0 {
						break // nobody has sent to us yet; wait for another worker's turn
					}
					drains += 1
					progressed = true
				}
			}
			complete := true
			for d in 0..<n {
				if pending[s][d] > 0 {
					complete = false
					break
				}
			}
			if complete {
				seeded[s] = true
				progressed = true
			}
		}

		// Phase 2: a worker that returned from its seed always drains. `.Spin` never gets here.
		for s in 0..<n {
			if !seeded[s] {
				continue
			}
			for src in 0..<n {
				if inflight[src][s] != 0 {
					inflight[src][s] = 0
					progressed = true
				}
			}
		}

		empty := true
		for s in 0..<n {
			for d in 0..<n {
				if inflight[s][d] != 0 {
					empty = false
					break
				}
			}
		}
		if remaining == 0 && empty {
			return true, round, drains
		}
		if !progressed {
			return false, round, drains // deadlock: full channels, nobody draining
		}
	}
	return false, max_rounds, drains
}
