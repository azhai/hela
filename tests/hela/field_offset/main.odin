#+dialect hela

// `#offset(N)` is the absolute form of a field placement: this field starts at byte N, whatever the
// alignment rules would have done. `#align(N)` answers "push this field out to the next multiple of
// N"; `#offset(N)` answers "this field is at N", which is what a wire header or a memory-mapped
// register block actually means.
//
// The difference matters when the gap is part of the format:
//
//     Registers :: struct {
//         #offset(0x00) control: u32,
//         #offset(0x04) status:  u32,
//         #offset(0x10) counter: u64,  // 8 reserved bytes are part of the register map
//         #offset(0x18) limit:   u32,
//     }
//
// Without `#offset`, `counter` would sit at byte 8: the compiler is not wrong, it is answering a
// different question. `#offset` is how the source says which question it is.
package field_offset

import "base:intrinsics"
import "core:fmt"

// A register block. The gaps are reserved registers: they have to stay there, so they are pinned
// rather than left to the ABI.
Registers :: struct {
	#offset(0x00) control: u32,
	#offset(0x04) status:  u32,
	#offset(0x10) counter: u64,
	#offset(0x18) limit:   u32,
}

#assert(offset_of_by_string(Registers, "control") == 0x00)
#assert(offset_of_by_string(Registers, "status")  == 0x04)
#assert(offset_of_by_string(Registers, "counter") == 0x10)
#assert(offset_of_by_string(Registers, "limit")   == 0x18)

// 0x18 + 4 = 0x1c, rounded up to the struct's 8-byte alignment.
#assert(size_of(Registers) == 32)
#assert(align_of(Registers) == 8)
// `#offset` does not raise the struct's alignment: a pinned field is already at a fixed distance
// from the start, so an array reproduces it as long as the offset is a multiple of the field's own
// alignment (which the checker enforces).

// 8 bytes between `status` and `counter`, 4 at the end. Both are visible to `intrinsics.layout_*`,
// so a `#assert` can tell "this gap is part of the map" from "this gap is the ABI".
#assert(intrinsics.layout_padding_of(Registers) == 12)
#assert(intrinsics.layout_tail_padding_of(Registers) == 4)

// `#offset` and `#explicit` are compatible, and this is the case that makes it worth having: the
// reserved bytes are declared by the pin, so `#explicit` does not have to be told about them.
Packet :: struct #explicit {
	#offset(0)  magic:  u32,
	#offset(4)  kind:   u16,
	#offset(6)  flags:  u16,
	#offset(8)  length: u32,
	// Bytes 12..16 are the reserved field of the format: pinned, not padded.
	#offset(16) seq:    u64,
}

#assert(offset_of_by_string(Packet, "magic")  == 0)
#assert(offset_of_by_string(Packet, "length") == 8)
#assert(offset_of_by_string(Packet, "seq")    == 16)
#assert(size_of(Packet) == 24)

// The same bytes, written the way `#explicit` used to require. Being able to drop the `_: [4]u8`
// is the point: the offset already says the four bytes are reserved.
Packet_Manual :: struct #explicit {
	magic:  u32,
	kind:   u16,
	flags:  u16,
	length: u32,
	_:      [4]u8,
	seq:    u64,
}
#assert(size_of(Packet) == size_of(Packet_Manual))
#assert(offset_of_by_string(Packet, "seq") == offset_of_by_string(Packet_Manual, "seq"))

// A polymorphic struct re-checks at every instantiation, so an absolute offset has to survive that
// like any other field placement.
Fixed_Head :: struct($T: typeid) {
	#offset(0)  tag:   u32,
	#offset(8)  value: T,
}
#assert(offset_of_by_string(Fixed_Head(u32), "value") == 8)
#assert(size_of(Fixed_Head(u32)) == 12)
#assert(offset_of_by_string(Fixed_Head(u64), "value") == 8)
#assert(size_of(Fixed_Head(u64)) == 16)

main :: proc() {
	r: Registers
	if offset_of(Registers, counter) != 0x10 {
		fmt.panicf("counter is at %d, not 0x10", offset_of(Registers, counter))
	}

	// The bytes on the wire are the map: write through the named fields, read through a byte view.
	r.control = 0xAABBCCDD
	r.status  = 0x11223344
	r.counter = 0x1122334455667788
	r.limit   = 0xDEADBEEF

	buf := cast([^]u8)&r
	if buf[0x00] != 0xDD || buf[0x03] != 0xAA {
		fmt.panicf("control is not at 0x00: %02x %02x %02x %02x", buf[0], buf[1], buf[2], buf[3])
	}
	if buf[0x04] != 0x44 || buf[0x07] != 0x11 {
		fmt.panicf("status is not at 0x04: %02x %02x %02x %02x", buf[4], buf[5], buf[6], buf[7])
	}
	// The reserved bytes are untouched by the named fields, which is what "reserved" means.
	for i in 0x08..<0x10 {
		if buf[i] != 0 {
			fmt.panicf("byte 0x%02x in the reserved gap is %x, not 0", i, buf[i])
		}
	}
	if buf[0x10] != 0x88 || buf[0x17] != 0x11 {
		fmt.panicf("counter is not at 0x10: %02x %02x ... %02x", buf[0x10], buf[0x11], buf[0x17])
	}
	if buf[0x18] != 0xEF || buf[0x1b] != 0xDE {
		fmt.panicf("limit is not at 0x18: %02x ... %02x", buf[0x18], buf[0x1b])
	}

	// In an array every element reproduces the map, because the offset is a multiple of each
	// field's own alignment (`#offset` never asks for a misaligned field).
	rs: [4]Registers
	for &x, i in rs {
		x.counter = u64(i) + 1
	}
	for &x, i in rs {
		if x.counter != u64(i)+1 {
			fmt.panicf("rs[%d].counter does not round-trip", i)
		}
		if uintptr(&x.counter)-uintptr(&x) != 0x10 {
			fmt.panicf("rs[%d].counter is at +%d", i, uintptr(&x.counter)-uintptr(&x))
		}
	}

	p: Packet
	p.magic  = 0x414C4548 // 'HELA', so byte 0 is 'H'
	p.kind   = 7
	p.flags  = 3
	p.length = 24
	p.seq    = 1
	pb := cast([^]u8)&p
	if pb[0] != 'H' || pb[4] != 7 {
		fmt.panicf("Packet does not have the declared offsets: %02x %02x %02x %02x", pb[0], pb[1], pb[2], pb[3])
	}
	if pb[12] != 0 || pb[15] != 0 {
		fmt.panicf("the pinned reserved bytes of Packet are not zero")
	}
	if pb[16] != 1 {
		fmt.panicf("Packet.seq is not at byte 16")
	}

	fmt.println("field offset tests: ok")
}
