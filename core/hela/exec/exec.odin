#+dialect hela
#+analysis alloc
#+analysis sharing

// core:hela/exec — thread-per-core / shared-nothing, wired out of the other core:hela packages.
//
// The unit is a Worker, not a task. `start` creates N threads and leaves them running on the same
// N mailboxes for the whole batch; there is no shared work queue, no work stealing and no mutex.
// Every (sender, receiver) pair owns ONE SPSC ring, so the hot path is a plain store + release,
// never a CAS on a line another core is using. That is the whole point: with a shared MPMC queue
// the enqueue cursor is a single cache line all producers fight over, and the layout manifest
// cannot tell you anything about it because the contention is not in the type.
//
//   worker 0 ──[0][1]──> worker 1      [s][d] = msg.Mailbox, one producer (s), one consumer (d)
//   worker 1 ──[1][0]──> worker 0      each mailbox has head/tail/slots on three separate lines
//
// Each worker also owns, exclusively:
//   mem.Arena      a slice carved out of one boot buffer, so the byte budget is fixed at start
//   event.Loop     its own queue + timer wheel, ticked once per round
//   cache.Cache    its own shards — no cross-core cache, no shared index
//   counters       on their own line, declared with #atomic + #share(worker)
//
// The only cross-worker state is the small Runtime header (counters, stop flag, a log ring).
// `hela-layout --contract` prints it as one owner per cache line; `#+analysis sharing` rejects
// the day somebody puts a worker-owned counter on the controller's line.
//
// `start` / `wait_idle` / `stop` implement a bounded batch: `expected` is the number of envelope
// deliveries the caller promises the seed + handler will produce. Nothing is polled with a timeout
// and nothing sleeps; the run ends when every promised delivery has been consumed. This is the
// DST-style "visible work budget" rather than a heuristic idle detector.
//
// `expected` is about WHEN to stop, not about how big the queues must be. M19 had to size every
// mailbox to cover the entire burst; M23 added `core:hela/flow` backpressure, so a channel that
// fills makes the blocked producer drain its own inbox. The work budget and the queue capacity
// are now independent numbers.
package exec

import "base:intrinsics"
import "core:sync"
import "core:thread"

import "core:hela/cache"
import "core:hela/event"
import "core:hela/flow"
import io "core:hela/io"
import "core:hela/log"
import mem "core:hela/mem"
import "core:hela/msg"
import "core:hela/supervise"

MAX_WORKERS   :: 8
MAX_BATCH     :: 32
Cache_Line    :: 64
LOOP_CAPACITY :: 16
LOG_CAPACITY  :: 256
CACHE_SHARDS  :: 4
CACHE_ENTRIES :: 16
DEFAULT_ARENA :: 64 * 1024

WORKER_NAMES :: [MAX_WORKERS]string{
	"w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7",
}

// A Seed runs once on each worker before it starts draining; a Handler runs on the worker thread
// for every delivered envelope. Neither may allocate implicitly (the file is `#+analysis alloc`),
// and neither may send after `stop` has been requested.
Seed       :: #type proc(w: ^Worker)
Handler    :: #type proc(w: ^Worker, e: ^msg.Envelope)
IO_Handler :: #type proc(w: ^Worker, c: io.Completion)

Config :: struct {
	workers:          int,
	mailbox_capacity: int, // power of two
	arena_bytes:      int, // per worker, carved from one boot buffer
	batch:            int, // envelopes drained per mailbox per round
	clock:            event.Clock,
	seed:             Seed,
	handler:          Handler,
	// Called from inside `event.loop_tick` when a real kernel completion is dispatched. It runs
	// on the worker's own thread, on the same deterministic path as every other event.
	io_handler:       IO_Handler,
}

default_config :: proc() -> Config {
	return Config{
		workers          = 4,
		mailbox_capacity = 64,
		arena_bytes      = DEFAULT_ARENA,
		batch            = 16,
		clock            = nil,
		seed             = nil,
		handler          = nil,
		io_handler       = nil,
	}
}

// Worker is laid out in declared bands, not by accident. `#align(Cache_Line)` puts each band on
// its own line; `#atomic` + `#share` say who writes it. The controller writes `stopped`, the
// worker writes its own counters, and the wiring on line 0 is frozen before any thread starts.
Worker :: struct {
	// line 0 — controller-written wiring, read-only while the workers run.
	#align(Cache_Line) rt: ^Runtime,
	id: int,
	count: int,
	thread: ^thread.Thread,
	batch: [^]msg.Envelope, // carved from this worker's arena

	// line 1 — worker-owned counters. Nothing else ever writes these.
	#align(Cache_Line) #atomic #share(worker) handled: u64,
	#atomic #share(worker) app_sum: u64,
	#atomic #share(worker) app_bad: u64,

	// line 2+ — worker-local state, no cross-thread access at all.
	#align(Cache_Line) arena: mem.Arena,
	loop: event.Loop,
	cache: cache.Cache,

	// Per-core I/O source: this worker owns its own kqueue/poll descriptor. No poller is shared
	// between cores, which is the I/O half of shared-nothing. `io.Source` is 64-byte aligned, so
	// it starts on its own line; its own contract declares `owner` for the counters.
	io_src: io.Source,

	// last line — controller-owned stop flag, isolated from the worker's lines.
	#align(Cache_Line) #atomic #share(controller) stopped: u64,
}

#assert(align_of(Worker) == Cache_Line)
#assert(offset_of_by_string(Worker, "handled") == Cache_Line)
#assert(offset_of_by_string(Worker, "arena") == 2 * Cache_Line)
#assert(offset_of_by_string(Worker, "stopped") % Cache_Line == 0)

// Worker_Stats is the controller-readable snapshot taken in `stop` before the worker array is
// released. Keeping it in Runtime means "what did each worker do?" is answerable after shutdown,
// without leaking the (much larger) worker array just to read a handful of u64s.
Worker_Stats :: struct {
	sum:            u64,
	handled:        u64,
	bad:            u64,
	ticks:          u64,
	posted:         u64,
	stopped:        u64,
	io_completions: u64,
	// Backpressure is observable, not a spin loop hidden in `send`: how often a push found a full
	// channel, how many pump rounds ran, and how many envelopes those rounds consumed.
	blocked:        u64,
	pump_rounds:    u64,
	pumped:         u64,
	spins:          u64,
}

Runtime :: struct {
	// line 0 — frozen config. Adding the I/O callback made `Config` exactly 64 B; the old
	// `expected` no longer fits here, and `#assert` caught it instead of letting the worker
	// counters drift to line 2 unnoticed.
	#align(Cache_Line) cfg: Config,

	// line 1 — the only worker-shared counters; all written by workers, same label.
	#align(Cache_Line) #atomic #share(workers) sent: u64,
	#atomic #share(workers) consumed: u64,
	#atomic #share(workers) dropped: u64,

	// line 2 — controller -> workers. `expected` belongs here: written once by the controller,
	// never by a worker. Leaving it on the workers' line would be false sharing with `sent`.
	#align(Cache_Line) #atomic #share(controller) stopping: u64,
	expected: u64,

	// line 3 — one MPMC log ring shared by every worker; formatting happens in `stop`.
	#align(Cache_Line) logs: log.Log,

	// line 4+ — the SPSC matrix. Each Mailbox carries its own three-line contract.
	#align(Cache_Line) boxes: [MAX_WORKERS][MAX_WORKERS]msg.Mailbox,

	// A slice, not an inline array: `Worker` contains lazily instantiated polymorphic types
	// (`event.Loop` -> `queue.Queue(Event)`), and an inline array would make Runtime's cached
	// field offsets depend on Worker's size before that size is final. The workers are carved
	// explicitly in `start`, which keeps the byte budget visible anyway.
	workers: []Worker,
	group: supervise.Group,
	handles: [MAX_WORKERS]supervise.Handle,
	backing: []u8,
	stats: [MAX_WORKERS]Worker_Stats,
	log_records: u64,
	started: bool,

	// One `flow.Gate` per worker, each on its own cache line. `exec` fixes the policy at `.Pump`:
	// its contract is "never drop a message", and pump is the only policy that guarantees forward
	// progress when every worker seeds at once. The other policies live in `core:hela/flow` for
	// other topologies. Snapshotted into `stats` in `stop`, so the counters survive shutdown.
	backpressure: flow.Table(MAX_WORKERS),
}

#assert(align_of(Runtime) == Cache_Line)
#assert(offset_of_by_string(Runtime, "sent") == Cache_Line)
#assert(offset_of_by_string(Runtime, "stopping") == 2 * Cache_Line)
#assert(offset_of_by_string(Runtime, "boxes") % Cache_Line == 0)
#assert(size_of(msg.Envelope) == msg.ENVELOPE_SIZE)
#assert(intrinsics.layout_cache_lines_of(msg.Envelope) == 2)

// encode / decode put a unique 64-bit value in the first 8 payload bytes without an unaligned
// cast. The test uses it as a litmus: the sum of every value delivered must equal the sum of
// every value sent, which catches lost, duplicated and double-delivered messages.
encode :: proc(dst: []u8, v: u64) {
	for i in 0..<8 {
		dst[i] = u8(v >> u64(8 * i))
	}
}

decode :: proc(src: []u8) -> u64 {
	v: u64 = 0
	for i in 0..<8 {
		v |= u64(src[i]) << u64(8 * i)
	}
	return v
}

// consume_batch dispatches n envelopes already sitting in `w.batch`. The main drain loop and the
// pump both go through here, so they cannot disagree about ordering: `consumed` is published only
// AFTER the handler returns. Publishing it earlier let `wait_idle` return while a handler was
// still accumulating the litmus sum (the M19 bug). `flow.enter/leave` mark the handler window so
// a nested `send` never pumps (which would recursively re-enter the handler and clobber `batch`).
consume_batch :: proc(w: ^Worker, n: int) {
	rt  := w.rt
	cfg := &rt.cfg
	g   := &rt.backpressure.gates[w.id]
	flow.enter(g)
	for i in 0..<n {
		e := &w.batch[i]
		sync.atomic_add_explicit(&w.handled, 1, .Relaxed)
		if cfg.handler != nil {
			cfg.handler(w, e)
		}
		sync.atomic_add_explicit(&rt.consumed, 1, .Release)
	}
	flow.leave(g)
}

// pump_inbox is the forward-progress half of M23. When this worker is blocked pushing, it drains
// its OWN inbound channels — which are exactly the channels other producers are blocked on. In an
// N x N matrix that is enough to break the "everyone seeds, nobody drains" deadlock without a
// shared queue, a credit protocol, or a drop. Called only when `flow.on_full` returns `.Drain`.
pump_inbox :: proc(w: ^Worker) -> int {
	rt    := w.rt
	total := 0
	for src in 0..<w.count {
		n := msg.drain(&rt.boxes[src][w.id], w.batch[:rt.cfg.batch])
		if n == 0 {
			continue
		}
		consume_batch(w, n)
		total += n
	}
	return total
}

// send publishes an envelope on the SPSC channel owned by (this worker, dst). Only this worker
// ever writes that ring, so there is no CAS. On the fast path (one successful push) no Gate is
// touched at all. A full channel is decided by `core:hela/flow`: `.Pump` drains our own inbox,
// `.Retry` spins, `.Abort` is an explicit reject. M19 sized the capacity to cover the whole
// burst; M23 removes that constraint — see 19-m23-forward-progress.md.
send :: proc(w: ^Worker, dst: int, e_in: msg.Envelope) -> bool {
	rt := w.rt
	if dst < 0 || dst >= w.count {
		sync.atomic_add_explicit(&rt.dropped, 1, .Relaxed)
		return false
	}
	if sync.atomic_load_explicit(&rt.stopping, .Acquire) != 0 {
		return false
	}
	// Odin procedure parameters are immutable; the source/destination are stamped by the runtime.
	e := e_in
	e.source = u64(w.id)
	e.destination = u64(dst)
	g := &rt.backpressure.gates[w.id]
	for !msg.send(&rt.boxes[w.id][dst], e) {
		switch flow.on_full(g) {
		case .Drain:
			n := pump_inbox(w)
			flow.note_drain(g, n)
			if n == 0 {
				// Nobody has sent to us yet. Back off so another worker gets a turn.
				flow.note_spin(g)
				flow.spin_hint()
			}
		case .Retry:
			flow.note_spin(g)
			flow.spin_hint()
		case .Abort:
			sync.atomic_add_explicit(&rt.dropped, 1, .Relaxed)
			return false
		}
	}
	sync.atomic_add_explicit(&rt.sent, 1, .Release)
	return true
}

// loop_handler keeps `posted` a gauge of unhandled events: `event.post` increments it on push,
// this decrements it when loop_tick dispatches. After a run every worker's loop must read 0.
//
// A real I/O completion is just another event here. `io.poll` never calls user code; this handler
// runs inside `event.loop_tick`, so "same posts + same clock + same kernel completions = same
// handler order" still holds. `l.user` is this worker, set once in `start`.
loop_handler :: proc(l: ^event.Loop, e: event.Event) {
	l.posted -= 1
	if e.kind != io.EVENT_IO || l.user == nil {
		return
	}
	w := cast(^Worker)l.user
	cfg := &w.rt.cfg
	if cfg.io_handler != nil {
		cfg.io_handler(w, io.event_to_completion(e))
	}
}

worker_main :: proc(data: rawptr) {
	w   := cast(^Worker)data
	rt  := w.rt
	cfg := &rt.cfg

	log.write(&rt.logs, .Info, u32(w.id), 0, "exec worker start")
	event.post(&w.loop, event.Event{kind = event.EVENT_USER, id = u64(w.id)})
	if cfg.seed != nil {
		cfg.seed(w)
	}

	for {
		stopping := sync.atomic_load_explicit(&rt.stopping, .Acquire) != 0
		taken := 0
		for src in 0..<w.count {
			mb := &rt.boxes[src][w.id]
			n := msg.drain(mb, w.batch[:cfg.batch])
			consume_batch(w, n)
			taken += n
		}
		// One non-blocking kernel wait per round, on this worker's own poller. `io.poll` only
		// publishes completions; the user handler still runs exclusively inside loop_tick.
		io.poll(&w.io_src, &w.loop, 0)
		event.loop_tick(&w.loop, cfg.batch)
		done := sync.atomic_load_explicit(&rt.consumed, .Acquire) >= rt.expected
		if stopping && done && taken == 0 {
			break
		}
		if taken == 0 {
			sync.cpu_relax()
		}
	}

	log.write(&rt.logs, .Info, u32(w.id), 0, "exec worker stop")
	// `stop()` joins this thread before it reads the flag, so the join already provides the
	// synchronization; a release store here would have no acquire load to pair with.
	sync.atomic_store_explicit(&w.stopped, 1, .Relaxed)
}

// start carves one boot buffer, builds the used part of the mailbox matrix, gives every worker
// its own arena / event loop / cache, and starts the threads. `expected` is the number of envelope
// deliveries the caller promises the seed + handler will produce in this batch.
start :: proc(rt: ^Runtime, cfg: Config, expected: u64, allocator := context.allocator) -> bool {
	if cfg.workers <= 0 || cfg.workers > MAX_WORKERS {
		return false
	}
	if cfg.batch <= 0 || cfg.batch > MAX_BATCH {
		return false
	}
	if cfg.mailbox_capacity <= 0 || cfg.mailbox_capacity & (cfg.mailbox_capacity - 1) != 0 {
		return false
	}
	if cfg.arena_bytes < cfg.batch * size_of(msg.Envelope) + 1024 {
		return false
	}

	rt.cfg          = cfg
	rt.expected     = expected
	rt.log_records  = 0
	rt.started      = false
	// exec never drops a message, so the only sound policy is Pump. Gate state is worker-local,
	// but it lives in the shared Runtime, hence one cache line per gate (see flow.Gate).
	flow.table_init(&rt.backpressure, .Pump)
	sync.atomic_store_explicit(&rt.stopping, 0, .Relaxed)
	sync.atomic_store_explicit(&rt.sent, 0, .Relaxed)
	sync.atomic_store_explicit(&rt.consumed, 0, .Relaxed)
	sync.atomic_store_explicit(&rt.dropped, 0, .Relaxed)

	// One allocation at boot, then every worker gets a disjoint slice. The byte budget is a
	// number in the config, not something discovered by an allocator at 3 a.m.
	rt.backing = make([]u8, cfg.workers * cfg.arena_bytes, allocator)
	if rt.backing == nil {
		return false
	}
	rt.workers = make([]Worker, cfg.workers, allocator)
	if rt.workers == nil {
		return false
	}
	for s in 0..<cfg.workers {
		for d in 0..<cfg.workers {
			if !msg.init(&rt.boxes[s][d], cfg.mailbox_capacity, allocator) {
				return false
			}
		}
	}
	if !log.init(&rt.logs, LOG_CAPACITY, .Info, allocator) {
		return false
	}

	// Workers are children of one supervision group; the policy decides, the caller restarts.
	supervise.group_init(&rt.group, .One_For_All, 2, 100)
	names := WORKER_NAMES // a constant array cannot be indexed with a variable
	for i in 0..<cfg.workers {
		h, ok := supervise.group_add(&rt.group, names[i])
		if !ok {
			return false
		}
		rt.handles[i] = h
	}

	for i in 0..<cfg.workers {
		w := &rt.workers[i]
		w.rt    = rt
		w.id    = i
		w.count = cfg.workers
		sync.atomic_store_explicit(&w.handled, 0, .Relaxed)
		sync.atomic_store_explicit(&w.app_sum, 0, .Relaxed)
		sync.atomic_store_explicit(&w.app_bad, 0, .Relaxed)
		sync.atomic_store_explicit(&w.stopped, 0, .Relaxed)

		mem.init(&w.arena, rt.backing[i*cfg.arena_bytes : (i+1)*cfg.arena_bytes])
		bytes, ok := mem.alloc_bytes(&w.arena, cfg.batch * size_of(msg.Envelope), align_of(msg.Envelope))
		if !ok {
			return false
		}
		w.batch = cast([^]msg.Envelope)raw_data(bytes)
		if !event.loop_init(&w.loop, LOOP_CAPACITY, cfg.clock, loop_handler, allocator) {
			return false
		}
		w.loop.user = w // so the loop handler can reach its own worker for I/O completions
		if !io.source_init(&w.io_src) {
			// No backend on this target (see `io.FULLY_SUPPORTED`): `io.poll` becomes a no-op and
			// the pure-message path still works. Failing the whole runtime here would make exec
			// unusable on a platform that simply has no I/O backend yet.
			w.io_src.kq = -1
		}
		if !cache.init(&w.cache, CACHE_SHARDS, CACHE_ENTRIES, allocator) {
			return false
		}
		w.thread = thread.create_and_start_with_data(w, worker_main)
		if w.thread == nil {
			return false
		}
	}
	rt.started = true
	return true
}

// wait_idle blocks until every promised delivery has been consumed. It is deliberately not a
// heuristic: with a known work budget, "idle" is an exact predicate.
wait_idle :: proc(rt: ^Runtime) {
	for sync.atomic_load_explicit(&rt.consumed, .Acquire) < rt.expected {
		sync.cpu_relax()
	}
}

// stop asks the workers to leave, joins them, drains the log, then releases everything. Call
// `wait_idle` (or just `stop`, which does it) before inspecting the counters.
stop :: proc(rt: ^Runtime, allocator := context.allocator) {
	if !rt.started {
		return
	}
	wait_idle(rt)
	sync.atomic_store_explicit(&rt.stopping, 1, .Release)
	for i in 0..<rt.cfg.workers {
		w := &rt.workers[i]
		if w.thread == nil {
			continue
		}
		thread.join(w.thread)
		thread.destroy(w.thread)
		w.thread = nil
	}

	// The log's producers are gone now, so a plain drain is race-free. `nil` sink means "count
	// them, do not format": formatting belongs off the worker's path.
	records: [MAX_BATCH]log.Record
	total := 0
	for {
		n := log.drain(&rt.logs, records[:], nil)
		total += n
		if n == 0 {
			break
		}
	}
	rt.log_records = u64(total)

	// Snapshot the per-worker outcome before releasing the worker array. After `stop`, the
	// controller reads `rt.stats[i]`, never `rt.workers[i]`.
	for i in 0..<rt.cfg.workers {
		w := &rt.workers[i]
		g := &rt.backpressure.gates[i]
		rt.stats[i] = Worker_Stats{
			sum            = sync.atomic_load_explicit(&w.app_sum, .Relaxed),
			handled        = sync.atomic_load_explicit(&w.handled, .Relaxed),
			bad            = sync.atomic_load_explicit(&w.app_bad, .Relaxed),
			ticks          = w.loop.ticks,
			posted         = w.loop.posted,
			stopped        = sync.atomic_load_explicit(&w.stopped, .Relaxed),
			io_completions = io.source_completions(&w.io_src),
			blocked        = g.blocked,
			pump_rounds    = g.drains,
			pumped         = g.delivered,
			spins          = g.spins,
		}
	}

	for s in 0..<rt.cfg.workers {
		for d in 0..<rt.cfg.workers {
			msg.destroy(&rt.boxes[s][d], allocator)
		}
	}
	for i in 0..<rt.cfg.workers {
		w := &rt.workers[i]
		io.source_destroy(&w.io_src)
		event.loop_destroy(&w.loop, allocator)
		cache.destroy(&w.cache, allocator)
	}
	log.destroy(&rt.logs, allocator)
	delete(rt.workers, allocator)
	rt.workers = nil
	delete(rt.backing, allocator)
	rt.backing = nil
	rt.started = false
}

// report_failure exposes the supervision policy as a pure decision. Handles are generational, so
// a report naming a worker from before a group restart is rejected instead of restarting it twice.
report_failure :: proc(rt: ^Runtime, worker_id: int, now: i64, restarted: []supervise.Handle) -> (action: supervise.Action, count: int) {
	if worker_id < 0 || worker_id >= rt.cfg.workers {
		return .Give_Up, 0
	}
	// Look the child up by name rather than using `handles`: after a group restart those stored
	// handles are stale by design, and a failure report must name the *current* worker.
	names := WORKER_NAMES
	h := supervise.group_find(&rt.group, names[worker_id])
	return supervise.report_failure(&rt.group, h, now, restarted)
}

worker_sum :: proc(rt: ^Runtime, i: int) -> u64 {
	return rt.stats[i].sum
}

worker_handled :: proc(rt: ^Runtime, i: int) -> u64 {
	return rt.stats[i].handled
}

total_bad :: proc(rt: ^Runtime) -> u64 {
	total: u64 = 0
	for i in 0..<rt.cfg.workers {
		total += rt.stats[i].bad
	}
	return total
}
