#+dialect hela

// The memory hierarchy of the machine the layout is being designed for, measured.
//
// Hela's whole claim is that the compiler knows where the bytes are. That claim is only useful if
// somebody also knows how those bytes are paid for: which level they land in, how long a dependent
// load takes there, how much bandwidth the level sustains, and where the plateau ends and DRAM
// begins. `#align(64)` / `#share` / cache-line-sized writers are decisions about this curve, so the
// curve is a deliverable, not folklore.
//
// Three questions this answers with numbers instead of intuition:
//
//   1. **What are the levels and how fast is each?** A pointer chase (dependent loads, no
//      prefetch to hide behind) over sizes from 16 KiB to 512 MiB gives nanoseconds per access;
//      the plateaus *are* L1 / L2 / DRAM. Streaming read and copy over the same sizes give
//      bandwidth, and multi-thread runs give the aggregate ceiling.
//   2. **Is SIMD actually being used?** `core:bytes.index_byte` is what the search path calls; it
//      already scans 64 B per iteration with four 128-bit NEON vectors on this target. The
//      interesting comparison is not "SIMD vs scalar" but "one pass with two candidates" vs the
//      two passes a case-insensitive search does today.
//   3. **read(2) into a heap buffer vs mmap** — the copy costs bandwidth that the scan could have
//      spent. mmap wins only if the page-fault cost of first touch is smaller than the copy.
//
// Everything is reported in GB/s and ns, not cycles: the clock is not exposed on this platform, so
// a cycle count would be an assumption dressed up as a measurement.
package membw

import "base:intrinsics"

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:simd"
import "core:sys/posix"
import "core:thread"
import "core:time"

KiB :: 1 << 10
MiB :: 1 << 20
GiB :: 1 << 30

// Enough traffic per measurement that the timer is not the signal, small enough that the whole
// probe finishes in about a minute.
TRAFFIC :: 256 * MiB

ns_since :: proc(t: time.Tick) -> f64 {
	return f64(time.duration_nanoseconds(time.tick_since(t)))
}

// ---------------------------------------------------------------- primitives

// One byte per 64 bytes: faults the pages in without dragging the whole buffer through the caches
// with a full store pass (which would leave the buffer dirty and make the read look slower).
touch :: proc(p: []u8) {
	for i := 0; i < len(p); i += 64 {
		p[i] = u8(i)
	}
}

// Four independent accumulators: the loop is memory bound, but a single accumulator would put the
// add latency on the critical path and under-report the bandwidth of the small levels.
sum64 :: proc(p: []u64) -> u64 {
	a, b, c, d: u64
	n := len(p)
	i := 0
	for ; i + 4 <= n; i += 4 {
		a += p[i]
		b += p[i + 1]
		c += p[i + 2]
		d += p[i + 3]
	}
	for ; i < n; i += 1 {
		a += p[i]
	}
	return a + b + c + d
}

u64_view :: proc(p: []u8) -> []u64 {
	return ([^]u64)(raw_data(p))[:len(p) / 8]
}

// ---------------------------------------------------------------- 1. latency

// Written by the chase below. A dependent-load loop whose result is unused is dead code, and LLVM
// happily deletes it — the first version of this probe reported 0.00 ns for every size because of
// exactly that.
sink: u64

// A random permutation turned into a linked list: each element stores the *index* of the next one,
// and elements are spread 128 B apart so that a 64 B cache line only ever holds one of them. The
// loads are dependent, so no prefetcher and no out-of-order window can overlap them — this measures
// the level the data actually lives in, which is exactly what a size sweep should expose.
latency_ns :: proc(size: int) -> f64 {
	STRIDE :: 128
	n := size / STRIDE
	if n < 4 {
		return 0
	}
	buf := make([]u8, n * STRIDE)
	defer delete(buf)
	p := ([^]u64)(raw_data(buf))
	idx := make([]u32, n)
	defer delete(idx)
	for i := 0; i < n; i += 1 {
		idx[i] = u32(i)
	}
	// xorshift: a fixed seed keeps two runs of this probe comparable.
	rng: u64 = 0x9e3779b97f4a7c15
	for i := n - 1; i > 0; i -= 1 {
		rng ~= rng << 13
		rng ~= rng >> 7
		rng ~= rng << 17
		j := int(rng % u64(i + 1))
		idx[i], idx[j] = idx[j], idx[i]
	}
	for i := 0; i < n; i += 1 {
		p[int(idx[i]) * (STRIDE / 8)] = u64(idx[(i + 1) % n])
	}

	accesses := 1 << 21
	best := max(f64)
	for _ in 0..<3 {
		cur: u64 = 0
		t0 := time.tick_now()
		for _ in 0..<accesses {
			cur = p[int(cur) * (STRIDE / 8)]
		}
		ns := ns_since(t0)
		sink ~= cur
		if ns < best {
			best = ns
		}
	}
	return best / f64(accesses)
}

// ---------------------------------------------------------------- 2. bandwidth

read_gbs :: proc(buf: []u8, reps: int) -> f64 {
	q := u64_view(buf)
	best := max(f64)
	for _ in 0..<3 {
		acc: u64
		t0 := time.tick_now()
		for _ in 0..<reps {
			acc ~= sum64(q)
		}
		ns := ns_since(t0)
		if acc == 1 {
			fmt.println(acc) // keeps the accumulation observable without printing in the timed loop
		}
		if ns < best {
			best = ns
		}
	}
	return f64(len(buf)) * f64(reps) / best
}

copy_gbs :: proc(dst, src: []u8, reps: int) -> f64 {
	best := max(f64)
	for _ in 0..<3 {
		t0 := time.tick_now()
		for _ in 0..<reps {
			copy(dst, src)
		}
		ns := ns_since(t0)
		if ns < best {
			best = ns
		}
	}
	// "Bytes moved" counts the read and the write: a copy that touches 256 MiB moves 512 MiB.
	return 2 * f64(len(src)) * f64(reps) / best
}

Thread_Job :: struct {
	slice: []u64,
	sum:   u64,
}

job_sum :: proc(data: rawptr) {
	j := cast(^Thread_Job)data
	j.sum = sum64(j.slice)
}

mt_gbs :: proc(buf: []u8, nthreads: int) -> f64 {
	q := u64_view(buf)
	jobs := make([]Thread_Job, nthreads)
	defer delete(jobs)
	chunk := len(q) / nthreads
	best := max(f64)
	for _ in 0..<3 {
		for i := 0; i < nthreads; i += 1 {
			jobs[i] = Thread_Job{slice = q[i * chunk:(i + 1) * chunk]}
		}
		ths := make([]^thread.Thread, nthreads)
		t0 := time.tick_now()
		for i := 0; i < nthreads; i += 1 {
			ths[i] = thread.create_and_start_with_data(&jobs[i], job_sum)
		}
		for i := 0; i < nthreads; i += 1 {
			thread.join(ths[i])
			thread.destroy(ths[i])
		}
		ns := ns_since(t0)
		delete(ths)
		if ns < best {
			best = ns
		}
	}
	return f64(chunk * nthreads * 8) / best
}

// ---------------------------------------------------------------- 3. scanning

// Two candidates in one pass. A case-insensitive search has two needles ('t' and 'T'), and the
// obvious implementation asks `index_byte` twice — two full sweeps of the same bytes. This does
// both in one sweep, which is the only SIMD win still available here: the per-byte cost is already
// one vector compare per 16 bytes inside `core:bytes`.
scan_pair_simd :: proc(s: []u8, a, b: u8) -> int {
	n := len(s)
	va := simd.u8x16(a)
	vb := simd.u8x16(b)
	i := 0
	for ; i + 64 <= n; i += 64 {
		hit: u8
		#unroll for j in 0..<4 {
			v := intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i + j * 16:]))
			hit |= simd.reduce_or(simd.lanes_eq(v, va)) | simd.reduce_or(simd.lanes_eq(v, vb))
		}
		if hit != 0 {
			// The block hit, but the vector mask does not say which lane: rescan the 64 bytes.
			for k := i; k < i + 64; k += 1 {
				if s[k] == a || s[k] == b {
					return k
				}
			}
		}
	}
	for ; i < n; i += 1 {
		if s[i] == a || s[i] == b {
			return i
		}
	}
	return -1
}

Scan_Fn :: proc(s: []u8) -> int

scan_gbs :: proc(s: []u8, fn: Scan_Fn) -> f64 {
	best := max(f64)
	for _ in 0..<5 {
		t0 := time.tick_now()
		r := fn(s)
		ns := ns_since(t0)
		if r >= 0 {
			fmt.panicf("scan probe must miss: found at %d", r)
		}
		if ns < best {
			best = ns
		}
	}
	return f64(len(s)) / best
}

// ---------------------------------------------------------------- 4. read vs mmap

// Exactly one page per iteration, straight from the device, so the number is the drive's
// sequential read speed rather than the page cache's. F_NOCACHE is Darwin's "do not populate the
// unified buffer cache with this" (`<sys/fcntl.h>`: `#define F_NOCACHE 48`).
F_NOCACHE :: 48

nocache_gbs :: proc(fd: posix.FD, length: int) -> f64 {
	posix.fcntl(fd, posix.FCNTL_Cmd(F_NOCACHE), 1)

	buf := make([]u8, 1 * MiB)
	defer delete(buf)
	best := max(f64)
	for _ in 0..<2 {
		off: int
		acc: u64
		t0 := time.tick_now()
		for off < length {
			want := min(len(buf), length - off)
			got := posix.pread(fd, raw_data(buf), uint(want), posix.off_t(off))
			if got <= 0 {
				break
			}
			acc ~= sum64(u64_view(buf[:int(got)]))
			off += int(got)
		}
		ns := ns_since(t0)
		if acc == 1 {
			fmt.println(acc)
		}
		if ns < best {
			best = ns
		}
	}
	return f64(length) / best
}

// The same device, N readers in flight. One synchronous read is a queue of depth 1: the drive is
// mostly idle waiting for the next request, so the number below is a *per-thread* limit, not the
// drive's. This is the measurement that decides whether reading files one at a time is leaving the
// SSD half empty.
Nocache_Job :: struct {
	fd:     posix.FD,
	off:    int,
	length: int,
	bytes:  f64,
}

nocache_job :: proc(data: rawptr) {
	j := cast(^Nocache_Job)data
	buf := make([]u8, 1 * MiB)
	defer delete(buf)
	off := j.off
	end := j.off + j.length
	for off < end {
		want := min(len(buf), end - off)
		got := posix.pread(j.fd, raw_data(buf), uint(want), posix.off_t(off))
		if got <= 0 {
			break
		}
		j.bytes += f64(got)
		off += int(got)
	}
}

nocache_mt_gbs :: proc(path: cstring, length: int, nthreads: int) -> f64 {
	chunk := length / nthreads
	jobs := make([]Nocache_Job, nthreads)
	defer delete(jobs)
	best := max(f64)
	for _ in 0..<2 {
		fds := make([]posix.FD, nthreads)
		defer delete(fds)
		for i := 0; i < nthreads; i += 1 {
			fds[i] = posix.open(path, {})
			posix.fcntl(fds[i], posix.FCNTL_Cmd(F_NOCACHE), 1)
			jobs[i] = Nocache_Job{fd = fds[i], off = i * chunk, length = chunk}
		}
		ths := make([]^thread.Thread, nthreads)
		t0 := time.tick_now()
		for i := 0; i < nthreads; i += 1 {
			ths[i] = thread.create_and_start_with_data(&jobs[i], nocache_job)
		}
		for i := 0; i < nthreads; i += 1 {
			thread.join(ths[i])
			thread.destroy(ths[i])
			posix.close(fds[i])
		}
		ns := ns_since(t0)
		delete(ths)
		if ns < best {
			best = ns
		}
	}
	total: f64
	for j in jobs {
		total += j.bytes
	}
	return total / best
}

read_file_gbs :: proc(path: string) -> f64 {
	best := max(f64)
	total: f64
	for _ in 0..<3 {
		t0 := time.tick_now()
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("read_entire_file: %v", err)
			return 0
		}
		acc := sum64(u64_view(data))
		ns := ns_since(t0)
		total = f64(len(data))
		delete(data)
		if acc == 1 {
			fmt.println(acc)
		}
		if ns < best {
			best = ns
		}
	}
	return total / best
}

// The mapping itself is one syscall; the cost that matters is the first touch of every page, so
// the fault time is inside the timed region on purpose.
mmap_gbs :: proc(fd: posix.FD, length: int) -> f64 {
	best := max(f64)
	for _ in 0..<3 {
		t0 := time.tick_now()
		p := posix.mmap(nil, uint(length), {.READ}, {.PRIVATE}, fd, 0)
		if p == nil || p == rawptr(posix.MAP_FAILED) {
			fmt.eprintln("mmap failed")
			return 0
		}
		acc := sum64(u64_view(([^]u8)(p)[:length]))
		posix.munmap(p, uint(length))
		ns := ns_since(t0)
		if acc == 1 {
			fmt.println(acc)
		}
		if ns < best {
			best = ns
		}
	}
	return f64(length) / best
}

// ---------------------------------------------------------------- report

row :: proc(label: string, bytes: int, ns: f64) {
	gbs := 0.0
	if ns > 0 {
		gbs = f64(bytes) / ns
	}
	fmt.printf("  %-10s %8s  %7.1f ns  %7.2f GB/s\n", label, human(bytes), ns, gbs)
}

human :: proc(n: int) -> string {
	if n >= MiB {
		return fmt.tprintf("%d MiB", n / MiB)
	}
	return fmt.tprintf("%d KiB", n / KiB)
}

// ---------------------------------------------------------------- assertions
//
// A probe that only prints numbers is a probe nobody re-runs. The properties below are decidable,
// so they are decided here rather than left for a reader to eyeball:
//
//   * the levels exist and are ordered (inner < mid < outer latency, by a factor),
//   * one pass with two candidates beats two passes with one candidate each,
//   * more threads read more bytes than one thread does.
//
// The thresholds are deliberately loose. They are there to catch a regression of *shape* — a second
// sweep creeping back into the scan path, the level structure disappearing under a bad access
// pattern — not to police how fast this particular machine is. A tight threshold on a machine with
// a noisy neighbour is a flaky test, which is worse than no test.
ASSERT_MIN_LEVEL_SPREAD :: 3.0   // outer level is at least 3x the inner one
ASSERT_MIN_MID_SPREAD   :: 1.3   // ...and there is something in between
ASSERT_MIN_ONE_PASS     :: 1.3   // one pass beats two passes by at least 30%
ASSERT_MIN_THREAD_GAIN  :: 1.2   // 10 threads beat 1 thread

failures: int

check :: proc(name: string, ok: bool, detail: string) {
	fmt.printf("  %s %-46s %s\n", ok ? "ok  " : "FAIL", name, detail)
	if !ok {
		failures += 1
	}
}

ratio :: proc(a, b: f64) -> f64 {
	if b <= 0 {
		return 0
	}
	return a / b
}

main :: proc() {
	quick := len(os.args) > 1 && os.args[1] == "quick"
	fmt.println("=== memory hierarchy probe (all numbers are measured, not looked up) ===")

	// ---- 1. latency: the plateaus are the levels.
	fmt.println("\n[1] dependent-load latency (random cycle, 128 B per element)")
	lat_sizes := [?]int{16 * KiB, 32 * KiB, 64 * KiB, 128 * KiB, 256 * KiB, 512 * KiB,
	                    1 * MiB, 2 * MiB, 4 * MiB, 8 * MiB, 16 * MiB, 64 * MiB, 256 * MiB}
	Lat_Sample :: struct { size: int, ns: f64 }
	lat_samples := make([dynamic]Lat_Sample, 0, len(lat_sizes))
	defer delete(lat_samples)
	for s in lat_sizes {
		if quick && s > 16 * MiB {
			continue
		}
		ns := latency_ns(s)
		append(&lat_samples, Lat_Sample{size = s, ns = ns})
		fmt.printf("  %8s  %6.2f ns/access\n", human(s), ns)
	}

	// ---- 2. streaming bandwidth, one thread.
	fmt.println("\n[2] streaming read bandwidth, 1 thread (sum, 4 accumulators)")
	bw_sizes := [?]int{8 * KiB, 32 * KiB, 128 * KiB, 512 * KiB, 2 * MiB, 8 * MiB,
	                   32 * MiB, 128 * MiB, 512 * MiB}
	bw_inner, bw_outer: f64
	bw_outer_size: int
	for s in bw_sizes {
		if quick && s > 8 * MiB {
			continue
		}
		buf := make([]u8, s)
		touch(buf)
		reps := max(1, TRAFFIC / s)
		gbs := read_gbs(buf, reps)
		if bw_inner == 0 {
			bw_inner = gbs // smallest: fits in the innermost cache
		}
		bw_outer = gbs // largest measured: DRAM
		bw_outer_size = s
		fmt.printf("  %8s  %7.2f GB/s\n", human(s), gbs)
		delete(buf)
	}

	// ---- 3. copy: read + write, so it is roughly half the read number when DRAM bound.
	fmt.println("\n[3] copy bandwidth, 1 thread (read + write counted together)")
	for s in bw_sizes {
		if quick && s > 8 * MiB {
			continue
		}
		src := make([]u8, s)
		dst := make([]u8, s)
		touch(src)
		reps := max(1, TRAFFIC / s)
		gbs := copy_gbs(dst, src, reps)
		fmt.printf("  %8s  %7.2f GB/s\n", human(s), gbs)
		delete(src)
		delete(dst)
	}

	// Collected for the assertion block at the end.
	agg_one, agg_best: f64
	scan_one, scan_two, scan_pair: f64

	// ---- 4. aggregate: does the memory system scale past one core?
	fmt.println("\n[4] aggregate read bandwidth, 512 MiB spread over N threads")
	{
		big := make([]u8, 512 * MiB)
		touch(big)
		counts := [?]int{1, 2, 4, 6, 8, 10}
		for t in counts {
			if quick && t > 4 {
				continue
			}
			gbs := mt_gbs(big, t)
			if t == 1 {
				agg_one = gbs
			}
			agg_best = max(agg_best, gbs)
			fmt.printf("  %2d thread(s)  %7.2f GB/s\n", t, gbs)
		}
		delete(big)
	}

	// ---- 5. scanning: the search path's actual inner loop.
	scan_size := 256 * MiB
	if quick {
		scan_size = 64 * MiB
	}
	fmt.printf("\n[5] byte scan over %s, needle absent (worst case: the whole budget)\n", human(scan_size))
	{
		s := make([]u8, scan_size)
		for i := 0; i < len(s); i += 1 {
			s[i] = 0xff
		}
		one: Scan_Fn = proc(s: []u8) -> int {
			return bytes.index_byte(s, 0x00)
		}
		// The shape xrep used to have: two independent sweeps, take the earlier hit.
		two: Scan_Fn = proc(s: []u8) -> int {
			a := bytes.index_byte(s, 0x00)
			b := bytes.index_byte(s, 0x01)
			return min(a, b)
		}
		pair: Scan_Fn = proc(s: []u8) -> int {
			return scan_pair_simd(s, 0x00, 0x01)
		}
		scan_one = scan_gbs(s, one)
		scan_two = scan_gbs(s, two)
		scan_pair = scan_gbs(s, pair)
		fmt.printf("  %-28s %7.2f GB/s\n", "index_byte (1 needle, 1 pass)", scan_one)
		fmt.printf("  %-28s %7.2f GB/s\n", "index_byte x2 (2 needles, 2 passes)", scan_two)
		fmt.printf("  %-28s %7.2f GB/s\n", "scan_pair_simd (2 needles, 1 pass)", scan_pair)
		delete(s)
	}

	// ---- 6. read(2) vs mmap vs the device itself.
	//
	// The file is written *through* an F_NOCACHE descriptor, so the pages are not left dirty in the
	// unified buffer cache: the first read below really goes to the drive. (Writing it the ordinary
	// way and reading it straight back measures DRAM, not the SSD — the first version of this probe
	// reported 14 GB/s for the "device" column because of that.)
	if quick {
		// The device numbers are the slowest part of the probe (1 GiB write + 1 GiB read) and they
		// are a property of the disk, not of the compiler. `run.sh` only needs "it compiles, it
		// runs, the scans are consistent"; the full picture comes from an explicit run.
		fmt.println("\n[6] skipped in quick mode")
	} else {
	fmt.println("\n[6] 1 GiB file: cold device read, then the two ways to get those bytes into a scan")
	{
		const_path :: "/tmp/hela_membw_probe.bin"
		c_path :: cstring("/tmp/hela_membw_probe.bin")
		FILE_SIZE :: 1 * GiB

		wfd := posix.open(c_path, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if wfd == -1 {
			fmt.eprintln("posix.open for write failed")
			return
		}
		posix.fcntl(wfd, posix.FCNTL_Cmd(F_NOCACHE), 1)
		chunk := make([]u8, 1 * MiB)
		for i := 0; i < len(chunk); i += 1 {
			chunk[i] = 0xff
		}
		written := 0
		for written < FILE_SIZE {
			n := posix.write(wfd, raw_data(chunk), uint(len(chunk)))
			if n <= 0 {
				break
			}
			written += int(n)
		}
		posix.close(wfd)
		delete(chunk)
		if written != FILE_SIZE {
			fmt.eprintfln("short write: %d of %d bytes", written, FILE_SIZE)
		}

		fd := posix.open(c_path, {})
		if fd == -1 {
			fmt.eprintln("posix.open for read failed")
			return
		}
		defer posix.close(fd)
		defer os.remove(const_path)

		fmt.printf("  %-32s %7.2f GB/s\n", "read + F_NOCACHE, 1 reader", nocache_gbs(fd, FILE_SIZE))
		readers := [?]int{2, 4, 8}
		for n in readers {
			fmt.printf("  %-32s %7.2f GB/s\n", fmt.tprintf("read + F_NOCACHE, %d readers", n),
			           nocache_mt_gbs(c_path, FILE_SIZE, n))
		}
		fmt.printf("  %-32s %7.2f GB/s\n", "read_entire_file + sum (now warm)", read_file_gbs(const_path))
		fmt.printf("  %-32s %7.2f GB/s\n", "mmap + sum, fresh map each time", mmap_gbs(fd, FILE_SIZE))
	}
	}

	// ---- 7. the shape of the curve, asserted.
	//
	// These are the numbers a layout decision rests on, so they are checked rather than printed and
	// left to a human. A machine that reorders levels, or a scan path that quietly grew a second
	// pass, fails here instead of shipping.
	fmt.println("\n[7] the shape of the curve")
	if len(lat_samples) >= 3 {
		inner := lat_samples[0]
		outer := lat_samples[len(lat_samples)-1]
		// The middle sample: the largest size at or below 4 MiB, which is an L2-ish working set on
		// every machine this probe has run on.
		mid := lat_samples[len(lat_samples)/2]
		for sample in lat_samples {
			if sample.size <= 4 * MiB {
				mid = sample
			}
		}
		spread := ratio(outer.ns, inner.ns)
		check("levels are ordered (outer >= 3x inner)", spread >= ASSERT_MIN_LEVEL_SPREAD,
			fmt.tprintf("%s %.2f ns -> %s %.2f ns = %.1fx",
				human(inner.size), inner.ns, human(outer.size), outer.ns, spread))
		mid_spread := ratio(outer.ns, mid.ns)
		check("there is a middle level", mid_spread >= ASSERT_MIN_MID_SPREAD,
			fmt.tprintf("%s %.2f ns is %.1fx faster than %s",
				human(mid.size), mid.ns, mid_spread, human(outer.size)))
	} else {
		check("levels are ordered (outer >= 3x inner)", false, "not enough samples")
	}
	// Measured, not assumed: a single thread's *streaming* read runs at the same rate whether the
	// bytes come from L2 or from DRAM -- on this machine 46.35 GB/s at a cache-sized buffer and
	// 45.50 GB/s at 512 MiB. One core's load path saturates before the memory subsystem does, so the
	// cache/DRAM difference does **not** show up as bandwidth; it shows up as latency (66x, asserted
	// above) and as *aggregate* bandwidth once more threads are involved (asserted below).
	//
	// The first version of this block asserted the opposite ("the inner level reads faster than
	// DRAM"), which is a plausible-sounding claim that this machine simply does not support: the
	// probe failed its own assertion the next time it ran. Keeping the number as a note is the
	// honest form -- the fact is real, it just isn't the fact the assertion claimed.
	if bw_outer_size >= 32 * MiB {
		fmt.printf("  note %-46s %s\n", "streaming read is level-independent",
			fmt.tprintf("%.2f GB/s (inner) vs %.2f GB/s (DRAM) = %.2fx -- the gap is latency, not bandwidth",
				bw_inner, bw_outer, ratio(bw_inner, bw_outer)))
	} else {
		fmt.printf("  skip %-46s %s\n", "streaming read is level-independent",
			"quick mode: no DRAM-sized sample")
	}
	check("threads buy bandwidth", ratio(agg_best, agg_one) >= ASSERT_MIN_THREAD_GAIN,
		fmt.tprintf("1 thread %.2f GB/s -> best %.2f GB/s = %.1fx",
			agg_one, agg_best, ratio(agg_best, agg_one)))
	// The one that matters for the search path: two candidates in one pass must beat one candidate
	// per pass, by a margin no amount of mapping noise can explain.
	check("two candidates in one pass beat two passes",
		ratio(scan_pair, scan_two) >= ASSERT_MIN_ONE_PASS,
		fmt.tprintf("%.2f GB/s vs %.2f GB/s = %.2fx",
			scan_pair, scan_two, ratio(scan_pair, scan_two)))
	// ...and a single candidate costs the same as a pair: the second compare is free, the second
	// sweep is not. Loose bound (0.8) because a two-candidate pass does twice the compare work.
	check("a second candidate in the same pass is nearly free",
		ratio(scan_pair, scan_one) >= 0.8,
		fmt.tprintf("%.2f GB/s vs %.2f GB/s = %.2fx",
			scan_pair, scan_one, ratio(scan_pair, scan_one)))

	if failures > 0 {
		fmt.eprintfln("\nmemory curve assertions: %d failure(s)", failures)
		os.exit(1)
	}
	fmt.println("\nmemory curve assertions: all ok")
}
