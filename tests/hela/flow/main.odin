#+dialect hela
// Deterministic, thread-free proof of the backpressure policy.
//
// The real evidence is `tests/hela/exec` running 4096 deliveries through a mailbox whose capacity
// is 8 (M19 needed 512). This file proves the *decision* is right independently of threads:
//   - the (policy, re-entrancy) truth table is checked exhaustively;
//   - Gate accounting is checked against a hand-computed sequence;
//   - `simulate` sweeps topologies and shows Spin/Reject deadlock while Pump always completes.
// No sleeps, no timeouts, no flaky scheduling: every result is a pure function of the inputs.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"

import "core:hela/flow"

#assert(flow.Cache_Line == 64)
#assert(size_of(flow.Gate) == 64)
#assert(align_of(flow.Gate) == 64)
#assert(intrinsics.layout_padding_of(flow.Gate) == 0)
#assert(offset_of_by_string(flow.Gate, "blocked") == 0)
#assert(offset_of_by_string(flow.Gate, "depth") == 32)
#assert(size_of(flow.Table(8)) == 512)
#assert(intrinsics.layout_padding_of(flow.Table(8)) == 0)

fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

check_plan :: proc() -> int {
	checked := 0
	for p in flow.Policy {
		for depth in 0..<8 {
			got := flow.plan(p, u32(depth))
			want: flow.Action
			switch p {
			case .Spin:
				want = .Retry
			case .Reject:
				want = .Abort
			case .Pump:
				if depth == 0 {
					want = .Drain
				} else {
					want = .Retry
				}
			}
			if got != want {
				fail("plan(%v, %d) = %v, want %v", p, depth, got, want)
			}
			checked += 1
		}
	}
	return checked
}

check_gate :: proc() {
	g: flow.Gate
	flow.gate_init(&g, .Pump)
	if flow.Policy(g.policy) != .Pump || g.blocked != 0 || g.depth != 0 {
		fail("gate_init did not reset the gate")
	}

	for _ in 0..<10 {
		a := flow.on_full(&g)
		if a != .Drain {
			fail("on_full outside a handler should request a drain")
		}
	}
	flow.note_drain(&g, 4)
	flow.note_drain(&g, 0)
	flow.note_drain(&g, 8)
	flow.note_spin(&g)
	flow.note_spin(&g)
	if g.blocked != 10 || g.drains != 3 || g.delivered != 12 || g.spins != 2 {
		fail("gate accounting: blocked=%d drains=%d delivered=%d spins=%d",
			g.blocked, g.drains, g.delivered, g.spins)
	}

	// Inside a handler, Pump must degrade to Retry rather than re-enter the handler.
	flow.enter(&g)
	flow.enter(&g)
	if g.depth != 2 || flow.on_full(&g) != .Retry {
		fail("re-entrant on_full must not request a drain")
	}
	flow.leave(&g)
	if flow.on_full(&g) != .Retry {
		fail("one leave is not enough to re-enable pumping")
	}
	flow.leave(&g)
	if g.depth != 0 || flow.on_full(&g) != .Drain {
		fail("balanced enter/leave should restore pumping")
	}
	flow.leave(&g) // must not underflow
	if g.depth != 0 {
		fail("leave underflowed the depth")
	}

	t: flow.Table(8)
	flow.table_init(&t, .Reject)
	for i in 0..<8 {
		if flow.Policy(t.gates[i].policy) != .Reject || t.gates[i].blocked != 0 {
			fail("table_init did not reach gate %d", i)
		}
	}
}

check_topology :: proc() -> (cases: int, spin_deadlocks: int, pump_completions: int) {
	capacities := [?]int{1, 2, 4, 8, 16}
	bursts     := [?]int{0, 1, 2, 3, 7, 16, 31, 64}
	for n in 2..=5 {
		for cap in capacities {
			for burst in bursts {
				max_rounds := 2000
				pump_done, _, pump_drains := flow.simulate(.Pump, n, cap, burst, max_rounds)
				spin_done, _, _           := flow.simulate(.Spin, n, cap, burst, max_rounds)
				rej_done, _, _            := flow.simulate(.Reject, n, cap, burst, max_rounds)
				cases += 1

				if !pump_done {
					fail("Pump did not finish: n=%d capacity=%d burst=%d", n, cap, burst)
				}
				if burst > cap {
					// This is the M19 failure: the batch does not fit, so pure retry deadlocks.
					if spin_done {
						fail("Spin should deadlock: n=%d capacity=%d burst=%d", n, cap, burst)
					}
					if rej_done {
						fail("Reject should not finish: n=%d capacity=%d burst=%d", n, cap, burst)
					}
					if pump_drains == 0 {
						fail("Pump finished without pumping: n=%d capacity=%d burst=%d", n, cap, burst)
					}
					spin_deadlocks += 1
					pump_completions += 1
				} else {
					// A batch that fits never blocks; every policy must finish.
					if !spin_done || !rej_done {
						fail("a batch that fits should finish under every policy: n=%d capacity=%d burst=%d", n, cap, burst)
					}
				}
			}
		}
	}
	return
}

main :: proc() {
	plan_cases := check_plan()
	check_gate()
	cases, spin_deadlocks, pump_completions := check_topology()

	fmt.printf("  flow: %d plan cases, %d topologies (n=2..5, capacity=1..16, burst=0..64)\n", plan_cases, cases)
	fmt.printf("  flow: %d Spin deadlocks detected, %d Pump completions with real drain rounds\n",
		spin_deadlocks, pump_completions)
	fmt.println("hela flow backpressure tests: ok")
}
