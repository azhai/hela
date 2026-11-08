#+dialect hela
#+analysis alloc
#+analysis sharing

// Fixed-size message envelopes and a lock-free mailbox for moving them between shards.
//
// tina's `Message_Envelope` is 128 bytes with the payload at byte 32; it maintains that wire
// format with `#assert(size_of == 128)`. Hela can go one step further: `#offset(N)` *is* the wire
// format, and `#explicit` makes the compiler reject any byte that is not named or deliberately
// reserved by a pin. There is no separate schema to keep in sync with the struct.
package msg

import "base:intrinsics"
import "core:sync"

import "core:hela/ring"

ENVELOPE_SIZE :: 128
PAYLOAD_SIZE  :: 96
USER_TAG_BASE :: 0x0040 // tags below this are reserved for the runtime (timer, io, control)
Cache_Line    :: 64

// The bytes ARE the protocol. Every gap is declared by the following `#offset`, so `#explicit`
// accepts it; nothing is left to the ABI's discretion.
Envelope :: struct #explicit {
	#offset(0)  source:       u64,
	#offset(8)  destination:  u64,
	#offset(16) tag:          u16,
	#offset(18) flags:        u16,
	#offset(20) payload_size: u16,
	#offset(24) correlation:  u32,
	#offset(32) payload:      [PAYLOAD_SIZE]u8,
}

#assert(size_of(Envelope) == ENVELOPE_SIZE)
#assert(offset_of_by_string(Envelope, "payload") == 32)
#assert(intrinsics.layout_padding_of(Envelope) == 6) // 22..23 and 28..31, both declared by pins

// A mailbox is one SPSC ring per (sender, receiver) pair. `dropped` sits on its own line so a
// producer counting rejects never invalidates the consumer's cursor line.
Mailbox :: struct {
	inbox: ring.Ring(Envelope),
	#align(Cache_Line) #atomic #share(consumer) dropped: u64,
}

#assert(offset_of_by_string(Mailbox, "dropped") == 3 * Cache_Line)

init :: proc(mb: ^Mailbox, capacity: int, allocator := context.allocator) -> bool {
	return ring.init(&mb.inbox, capacity, allocator)
}

destroy :: proc(mb: ^Mailbox, allocator := context.allocator) {
	ring.destroy(&mb.inbox, allocator)
}

// make builds a user message. Tags below USER_TAG_BASE are reserved, so an isolate cannot forge a
// timer completion by writing the wrong tag.
make :: proc(source, destination: u64, tag: u16, correlation: u32, data: []u8) -> (e: Envelope, ok: bool) {
	if tag < USER_TAG_BASE || len(data) > PAYLOAD_SIZE {
		return {}, false
	}
	e.source       = source
	e.destination  = destination
	e.tag          = tag
	e.correlation  = correlation
	e.payload_size = u16(len(data))
	for i in 0..<len(data) {
		e.payload[i] = data[i]
	}
	return e, true
}

payload_of :: proc(e: ^Envelope) -> []u8 {
	return e.payload[:int(e.payload_size)]
}

// send publishes one envelope. Single producer per mailbox.
send :: proc(mb: ^Mailbox, e: Envelope) -> bool {
	return ring.push(&mb.inbox, e)
}

// send_retry records a rejected send instead of silently losing it.
send_retry :: proc(mb: ^Mailbox, e: Envelope) -> bool {
	if ring.push(&mb.inbox, e) {
		return true
	}
	sync.atomic_add_explicit(&mb.dropped, 1, .Relaxed)
	return false
}

// recv reads one envelope. Single consumer per mailbox.
recv :: proc(mb: ^Mailbox) -> (e: Envelope, ok: bool) {
	return ring.pop(&mb.inbox)
}

// drain takes up to `len(dst)` envelopes in one pass. One cursor store per batch, not per message:
// this is the part that makes a thread-per-core runtime fast under load.
drain :: proc(mb: ^Mailbox, dst: []Envelope) -> int {
	count := 0
	for &slot in dst {
		e, ok := ring.pop(&mb.inbox)
		if !ok {
			break
		}
		slot = e
		count += 1
	}
	return count
}
