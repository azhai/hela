#+dialect hela
#+analysis alloc

// Benchmarks whose numbers mean something. A single timed loop is a rumour; this is warmup +
// N independent rounds + sorted samples + median/p99, with machine-readable JSON output.
//
// The existing `tests/hela/ring` measured false sharing with one hand-written timer. This package
// is the replacement: `hela bench --json` material for CI regressions, without pulling in a
// benchmarking framework or a hidden allocator.
package bench

import "core:fmt"
import "core:strings"
import "core:time"

Config :: struct {
	warmup:     int, // rounds not measured
	rounds:     int, // rounds measured
	iterations: int, // body calls per round
}

Result :: struct {
	name:           string,
	samples:        []f64, // nanoseconds per operation, one per round
	median:         f64,
	p99:            f64,
	min:            f64,
	max:            f64,
	ops_per_second: f64,
}

default_config :: proc() -> Config {
	return Config{warmup = 3, rounds = 9, iterations = 1000}
}

// insertion_sort is enough for a handful of rounds and needs no allocation or callback.
insertion_sort :: proc(xs: []f64) {
	for i in 1..<len(xs) {
		v := xs[i]
		j := i - 1
		for j >= 0 && xs[j] > v {
			xs[j + 1] = xs[j]
			j -= 1
		}
		xs[j + 1] = v
	}
}

percentile :: proc(xs: []f64, p: f64) -> f64 {
	if len(xs) == 0 {
		return 0
	}
	i := int(p * f64(len(xs) - 1))
	if i < 0 {
		i = 0
	}
	if i >= len(xs) {
		i = len(xs) - 1
	}
	return xs[i]
}

// run times `body(iterations)` once per round and returns ns/op. `body` must not be reordered by
// the optimiser: do real work (e.g. atomic stores) inside it, not a loop the compiler can fold.
run :: proc(name: string, cfg: Config, body: proc(iterations: int), allocator := context.allocator) -> (r: Result, ok: bool) {
	if cfg.rounds <= 0 || cfg.iterations <= 0 || body == nil {
		return {}, false
	}
	for _ in 0..<cfg.warmup {
		body(cfg.iterations)
	}
	r.name = name
	r.samples = make([]f64, cfg.rounds, allocator)
	if r.samples == nil {
		return {}, false
	}
	for i in 0..<cfg.rounds {
		start := time.tick_now()
		body(cfg.iterations)
		elapsed := time.tick_since(start)
		r.samples[i] = f64(i64(elapsed)) / f64(cfg.iterations)
	}
	insertion_sort(r.samples)
	r.min   = r.samples[0]
	r.max   = r.samples[cfg.rounds - 1]
	r.median = percentile(r.samples, 0.50)
	r.p99    = percentile(r.samples, 0.99)
	if r.median > 0 {
		r.ops_per_second = 1_000_000_000 / r.median
	}
	return r, true
}

// result_json appends one JSON object. JSON is written by hand: no reflection, no hidden
// allocation, and the key order is fixed so two runs produce byte-identical output.
result_json :: proc(b: ^strings.Builder, r: ^Result) {
	fmt.sbprintf(b, "{\"name\":\"%s\",\"rounds\":%d,\"median_ns_per_op\":%v,\"p99_ns_per_op\":%v,\"min_ns_per_op\":%v,\"max_ns_per_op\":%v,\"ops_per_second\":%v}\n",
		r.name, len(r.samples), r.median, r.p99, r.min, r.max, r.ops_per_second)
}

// result_line is the human-readable one-liner.
result_line :: proc(b: ^strings.Builder, r: ^Result) {
	fmt.sbprintf(b, "%-24s median %12v ns/op  p99 %12v ns/op  %14v ops/s\n",
		r.name, r.median, r.p99, r.ops_per_second)
}
