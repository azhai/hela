#+dialect hela
#+analysis alloc
#+analysis sharing

// Lock-free, fixed-record logging. The hot path is a copy into a 64-byte record and one push to a
// bounded MPMC ring; formatting and I/O happen in the drain phase, on a different thread.
//
// tina's `Log_Ring_Buffer` batches PIPE_BUF-sized writes and never calls fmt on the producer's
// path; oboe's logdb batches rows before sorting and flushing. Both are the same idea: pay the
// I/O cost once per batch, not once per record. Here the record header is `#explicit` + `#offset`,
// so the wire format is checked by the compiler instead of by a `#assert` someone might delete.
package log

import "core:sync"

import "core:hela/queue"

RECORD_SIZE  :: 64
MESSAGE_SIZE :: 40
Cache_Line   :: 64

Level :: enum u8 {
	Trace,
	Debug,
	Info,
	Warn,
	Error,
	Fatal,
}

// 64 bytes exactly, so one record is one cache line. The gaps at 13..15 and 18..23 are declared
// by the pins that follow them; `#explicit` accepts them because a pin is a statement, not an
// accident of the ABI.
Record :: struct #explicit {
	#offset(0)  time_ns:   u64,
	#offset(8)  thread_id: u32,
	#offset(12) level:     u8,
	#offset(16) length:    u16,
	#offset(24) message:   [MESSAGE_SIZE]u8,
}

#assert(size_of(Record) == RECORD_SIZE)
#assert(offset_of_by_string(Record, "message") == 24)

Log :: struct {
	q: queue.Queue(Record),
	#align(Cache_Line) #atomic #share(producers) dropped: u64,
	min_level: Level,
}

init :: proc(l: ^Log, capacity: int, min_level: Level, allocator := context.allocator) -> bool {
	if !queue.init(&l.q, capacity, allocator) {
		return false
	}
	l.min_level = min_level
	return true
}

destroy :: proc(l: ^Log, allocator := context.allocator) {
	queue.destroy(&l.q, allocator)
}

// write is the producer's entire job: no fmt, no allocation, no syscall. Long messages are
// truncated; that is a deliberate bound, not a surprise.
write :: proc(l: ^Log, level: Level, thread_id: u32, time_ns: i64, text: string) -> bool {
	if level < l.min_level {
		return true
	}
	r: Record
	r.time_ns   = u64(time_ns)
	r.thread_id = thread_id
	r.level     = u8(level)
	n := len(text)
	if n > MESSAGE_SIZE {
		n = MESSAGE_SIZE
	}
	r.length = u16(n)
	for i in 0..<n {
		r.message[i] = text[i]
	}
	if !queue.push(&l.q, r) {
		sync.atomic_add_explicit(&l.dropped, 1, .Relaxed)
		return false
	}
	return true
}

// drain consumes up to `len(dst)` records in one pass and calls `sink` for each. The sink may
// format, write to a file, or aggregate — it is off the producer's path.
drain :: proc(l: ^Log, dst: []Record, sink: proc(^Record)) -> int {
	count := queue.pop_batch(&l.q, dst)
	if sink == nil {
		return count
	}
	for i in 0..<count {
		sink(&dst[i])
	}
	return count
}

// message_of gives the sink a slice view; no copy on the read side either.
message_of :: proc(r: ^Record) -> string {
	return string(r.message[:int(r.length)])
}

dropped_count :: proc(l: ^Log) -> u64 {
	return sync.atomic_load_explicit(&l.dropped, .Relaxed)
}

pending :: proc(l: ^Log) -> int {
	return queue.length(&l.q)
}
