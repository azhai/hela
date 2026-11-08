#+dialect hela
#+analysis alloc

// Reusable bit-pattern matching, end to end.
//
// The header's bit layout is declared once in `Header`. Every rule is *derived* from it with
// `pattern.term` / `pattern.and_rule`, using the compiler's own segment table — no hand-written
// masks. The oracles below deliberately use hand-computed shifts: they are an independent
// implementation, so a wrong derived mask cannot pass by agreeing with itself.
//
// Two different bit_field types (16-bit and 32-bit) are compiled into the same generic
// `pattern.Table` structure: that is the reusable part. Every word of the 16-bit space and all
// 16*4096 op/channel combinations of the 32-bit space are checked against both the oracle and
// the library's naive linear matcher, so a mis-compiled decision tree (a shadowed or dropped
// rule) cannot hide.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"

import "core:hela/pattern"

Header :: bit_field u16 {
	kind:  u8  | 3,
	flags: u8  | 5,
	tag:   u16 | 8,
}

Frame :: bit_field u32 {
	op:      u8  | 4,
	channel: u16 | 12,
	seq:     u32 | 16,
}

ID_DATA :: 1
ID_PING :: 2
ID_ACK  :: 3
ID_ERR  :: 4

F_DATA :: 101
F_CTRL :: 102
F_END  :: 103

// The compile-time half: masks and encoded values are compiler constants, so they can be pinned
// in #assert and used as array lengths. These are the same values -emit-layout exports as
// `bit_mask`.
#assert(size_of(Header) == 2)
#assert(intrinsics.type_field_bit_offset(Header, "kind") == 0)
#assert(intrinsics.type_field_bit_size(Header, "kind") == 3)
#assert(intrinsics.type_field_bit_offset(Header, "flags") == 3)
#assert(intrinsics.type_field_bit_size(Header, "flags") == 5)
#assert(intrinsics.layout_bit_mask_of(Header, "kind") == 0x0007)
#assert(intrinsics.layout_bit_mask_of(Header, "flags") == 0x00f8)
#assert(intrinsics.layout_bit_mask_of(Header, "tag") == 0xff00)
#assert(intrinsics.layout_bit_encode_of(Header, "kind", 7) == 0x0007)
#assert(intrinsics.layout_bit_encode_of(Header, "flags", 21) == 0x00a8)
#assert(intrinsics.layout_bit_encode_of(Header, "tag", 0xab) == 0xab00)
#assert(intrinsics.layout_bit_mask_of(Frame, "op") == 0x0000000f)
#assert(intrinsics.layout_bit_mask_of(Frame, "channel") == 0x0000fff0)
#assert(intrinsics.layout_bit_mask_of(Frame, "seq") == 0xffff0000)
#assert(size_of(pattern.Table(4)) == 752)

fail :: proc(msg: string) {
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

// Independent oracle, written from the wire spec rather than from the type.
header_oracle :: proc(word: u64) -> (u32, bool) {
	kind  := word & 0x7
	flags := (word >> 3) & 0x1f
	tag   := (word >> 8) & 0xff
	if kind == 1 {
		return ID_DATA, true
	}
	if kind == 2 && flags == 0 {
		return ID_PING, true
	}
	if kind == 3 && flags == 1 {
		return ID_ACK, true
	}
	if kind == 0 && tag == 0xab {
		return ID_ERR, true
	}
	return 0, false
}

frame_oracle :: proc(word: u64) -> (u32, bool) {
	op      := word & 0xf
	channel := (word >> 4) & 0xfff
	if op == 1 {
		return F_DATA, true
	}
	if op == 2 && channel == 7 {
		return F_CTRL, true
	}
	if op == 15 {
		return F_END, true
	}
	return 0, false
}

main :: proc() {
	fmt.println("hela pattern tests:")

	// Rules are built from the declaration, not from hex literals.
	r_data := pattern.term(Header, "kind", 1, ID_DATA)
	r_ping, ping_ok := pattern.and_rule(
		pattern.term(Header, "kind", 2, 0),
		pattern.term(Header, "flags", 0, 0),
		ID_PING,
	)
	r_ack, ack_ok := pattern.and_rule(
		pattern.term(Header, "kind", 3, 0),
		pattern.term(Header, "flags", 1, 0),
		ID_ACK,
	)
	r_err, err_ok := pattern.and_rule(
		pattern.term(Header, "kind", 0, 0),
		pattern.term(Header, "tag", 0xab, 0),
		ID_ERR,
	)
	if !ping_ok || !ack_ok || !err_ok {
		fail("and_rule rejected a compatible pair")
	}

	rules := [4]pattern.Rule{r_data, r_ping, r_ack, r_err}
	table: pattern.Table(4)
	if !pattern.build(&table, rules[:]) {
		fail("build rejected a mutually exclusive rule set")
	}

	matched := 0
	for w in 0..<65536 {
		word := u64(w)
		got_id, got_ok := pattern.match(&table, word)
		ref_id, ref_ok := pattern.linear_match(&table, word)
		want_id, want_ok := header_oracle(word)
		if got_ok != want_ok || (got_ok && got_id != want_id) {
			fail("decision tree disagrees with the header oracle")
		}
		if got_ok != ref_ok || (got_ok && got_id != ref_id) {
			fail("decision tree disagrees with the naive linear matcher")
		}
		if got_ok {
			matched += 1
		}
	}
	for w in 0..<256 {
		if pattern.decode(Header, "flags", u64(w)) != (u64(w) >> 3) & 0x1f {
			fail("decode disagrees with the wire spec")
		}
	}
	fmt.printf("  header: 65536 words exhaustively checked, %d matched\n", matched)

	// The same structure, a different bit_field width and a different rule set.
	f_data := pattern.term(Frame, "op", 1, F_DATA)
	f_ctrl, ctrl_ok := pattern.and_rule(
		pattern.term(Frame, "op", 2, 0),
		pattern.term(Frame, "channel", 7, 0),
		F_CTRL,
	)
	f_end := pattern.term(Frame, "op", 15, F_END)
	if !ctrl_ok {
		fail("and_rule rejected the frame pair")
	}
	frame_rules := [3]pattern.Rule{f_data, f_ctrl, f_end}
	frame: pattern.Table(3)
	if !pattern.build(&frame, frame_rules[:]) {
		fail("frame build failed")
	}
	frame_matched := 0
	for i in 0..<65536 {
		op      := i & 15
		channel := (i >> 4) & 0xfff
		seq     := (i * 7919) & 0xffff
		word    := u64(op) | u64(channel) << 4 | u64(seq) << 16
		got_id, got_ok := pattern.match(&frame, word)
		ref_id, ref_ok := pattern.linear_match(&frame, word)
		want_id, want_ok := frame_oracle(word)
		if got_ok != want_ok || (got_ok && got_id != want_id) {
			fail("frame tree disagrees with the frame oracle")
		}
		if got_ok != ref_ok || (got_ok && got_id != ref_id) {
			fail("frame tree disagrees with the naive linear matcher")
		}
		if got_ok {
			frame_matched += 1
		}
	}
	fmt.printf("  frame: 65536 words checked, %d matched\n", frame_matched)

	// A shadowed rule must be rejected, not silently misrouted.
	overlap := [2]pattern.Rule{
		pattern.term(Header, "kind", 1, 10),
		pattern.term(Header, "kind", 1, 11),
	}
	bad: pattern.Table(2)
	if pattern.build(&bad, overlap[:]) {
		fail("build accepted overlapping rules")
	}
	ok, a, b := pattern.validate(&bad, 2)
	if ok || a != 0 || b != 1 {
		fail("validate did not report the overlapping pair")
	}
	_, conflict_ok := pattern.and_rule(
		pattern.term(Header, "kind", 1, 0),
		pattern.term(Header, "kind", 2, 0),
		0,
	)
	if conflict_ok {
		fail("and_rule accepted contradictory constraints")
	}
	fmt.println("  no shadowed rules")

	// An unbuilt table is not a match-anything table.
	empty: pattern.Table(2)
	_, empty_ok := pattern.match(&empty, 0)
	if empty_ok {
		fail("an unbuilt table matched a word")
	}

	fmt.println("hela pattern tests: ok")
}
