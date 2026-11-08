#+dialect hela
#+analysis alloc

// Reusable bit-pattern matching.
//
// A wire header (`bit_field u16 { kind: u8 | 3, flags: u8 | 5, ... }`) is a *language structure*:
// the compiler already owns which bits belong to which field. A routing table should not restate
// that as hex literals — every restatement is a chance to drift. Here a rule is derived from the
// type with `term(T, "field", value)` and combined with `and_rule`, then compiled once into a
// read-only decision tree that matches a word by testing individual bits.
//
//   rules := []Rule{
//       and_term(term(Header, "kind", 1, ID_DATA), term(Header, "flags", 0, ID_DATA)).rule,
//       ...
//   }
//   table: Table(8)
//   build(&table, rules)          // rejects overlapping rules
//   id, ok := match(&table, word) // no allocation, no hashing, no branch on rule count
//
// Rules must be mutually exclusive: `build` rejects a pair that could match the same word, so the
// tree's answer cannot depend on rule order. That is the property a protocol dispatch table needs
// (a shadowed rule is a silent misroute), and it is checked rather than documented.
//
// The shapes below are written with `#explicit`, so the bytes of the table itself are pinned and
// exported by `-emit-layout`: a worker can share one built table read-only with zero allocation,
// and a model can see that a node is 16 B and a rule 24 B without guessing.
package pattern

import "base:intrinsics"

NO_RULE :: ~u32(0)
NO_NODE :: ~u32(0)
LEAF_BIT :: u8(0xff)
FLAG_BUILT :: u32(1)

// A rule matches word when (word & mask) == value. `value` outside `mask` must be zero.
// 24 B: no padding, one third of a cache line.
//
// `#align(8)` is not decoration: on linux_i386 a `u64` only aligns to 4, so without it the
// struct's alignment (and therefore the `layout_hash` of every table built from it) would drift
// from the 64-bit targets even though the bytes are the same. The alignment is part of the wire
// contract because an array of rules must lay out identically everywhere.
Rule :: struct #explicit #align(8) {
	mask:  u64,
	value: u64,
	id:    u32,
	flags: u32,
}

#assert(size_of(Rule) == 24)
#assert(align_of(Rule) == 8)
#assert(intrinsics.layout_padding_of(Rule) == 0)

// One node of the decision tree. `bit == LEAF_BIT` means `rule` is an index into `rules`
// (NO_RULE = no match); otherwise the word's bit selects `zero` / `one`. 16 B, four per line.
//
// A leaf stores a rule index, not a result. The tree only *narrows* the candidates: a word can
// reach a leaf without satisfying every bit that rule cares about (bits used to split other
// branches are never tested on this path). `match` therefore does one final `(word & mask) ==
// value` check at the leaf. Skipping it is the classic "shadowed rule" bug: two mutually
// exclusive rules can still both be *absent* for a word, and the tree would report the survivor
// as a match.
Node :: struct #explicit {
	zero: u32,
	one:  u32,
	rule: u32,
	bit:  u8,
	_:    [3]u8,
}

#assert(size_of(Node) == 16)
#assert(intrinsics.layout_padding_of(Node) == 0)

// A fixed-capacity table: N rules and a node pool. A rule that "does not care" about the tested
// bit is copied into both branches, so the pool is deliberately generous (8N+8); `build` fails
// cleanly if a pathological rule set needs more. No allocator is involved anywhere.
Table :: struct($N: int) #explicit {
	rules:      [N]Rule,
	nodes:      [8 * N + 8]Node,
	node_count: u32,
	root:       u32,
	flags:      u32,
	_:          [4]u8, // align the tail to 8 B, explicitly named
}

Table_4 :: Table(4)
#assert(size_of(Table_4) == 752)
#assert(intrinsics.layout_padding_of(Table_4) == 0)

// term derives one field constraint from the bit_field declaration. Both the mask and the encoded
// value come from the compiler's segment table (see layout_bit_mask_of / layout_bit_encode_of), so
// changing the header in source changes every rule derived from it, automatically.
term :: proc($T: typeid, $name: string, $value: u64, id: u32) -> Rule {
	return Rule{
		mask  = intrinsics.layout_bit_mask_of(T, name),
		value = intrinsics.layout_bit_encode_of(T, name, value),
		id    = id,
		flags = 0,
	}
}

// and_rule is the rule algebra: two constraints on different bits become one rule. Constraints
// that disagree on a shared bit cannot describe any word, so the combination fails.
and_rule :: proc(a, b: Rule, id: u32) -> (rule: Rule, ok: bool) {
	shared := a.mask & b.mask
	if shared != 0 && (a.value & shared) != (b.value & shared) {
		return {}, false
	}
	return Rule{
		mask  = a.mask | b.mask,
		value = a.value | b.value,
		id    = id,
		flags = a.flags | b.flags,
	}, true
}

// decode extracts one field's unshifted value from a word, using the same compiler-owned mask.
decode :: proc($T: typeid, $name: string, word: u64) -> u64 {
	offset := intrinsics.type_field_bit_offset(T, name)
	return (word & intrinsics.layout_bit_mask_of(T, name)) >> uint(offset)
}

// validate checks the preconditions that make the tree's answer order-independent:
//   - every rule cares about at least one bit (a mask of 0 would match everything),
//   - no value bit sits outside the rule's mask,
//   - no two rules can match the same word (they agree on every bit both care about).
validate :: proc(t: ^Table($N), count: int) -> (bool, int, int) {
	if count > N {
		return false, -1, -1
	}
	for i in 0..<count {
		if t.rules[i].mask == 0 {
			return false, i, i
		}
		if t.rules[i].value & ~(t.rules[i].mask) != 0 {
			return false, i, i
		}
		for j in i + 1..<count {
			shared := t.rules[i].mask & t.rules[j].mask
			if shared != 0 && (t.rules[i].value & shared) == (t.rules[j].value & shared) {
				return false, i, j
			}
		}
	}
	return true, -1, -1
}

new_node :: proc(t: ^Table($N)) -> u32 {
	if t.node_count >= u32(len(t.nodes)) {
		return NO_NODE
	}
	idx := t.node_count
	t.node_count += 1
	t.nodes[idx] = {}
	return idx
}

// split builds the tree recursively. The chosen bit balances the two branches; a rule that does
// not care about it goes to both. Mutual exclusivity (checked by validate) means a word can be
// consistent with at most one rule, so the leaf names a single *candidate* and the answer is
// independent of rule order. It is not yet a match: `match` still verifies that candidate's full
// mask, because bits that were never used to split a branch have not been tested on this path.
split :: proc(t: ^Table($N), cands: []u16) -> u32 {
	if len(cands) == 0 {
		idx := new_node(t)
		if idx == NO_NODE {
			return NO_NODE
		}
		t.nodes[idx].bit = LEAF_BIT
		t.nodes[idx].rule = NO_RULE
		return idx
	}
	if len(cands) == 1 {
		idx := new_node(t)
		if idx == NO_NODE {
			return NO_NODE
		}
		t.nodes[idx].bit = LEAF_BIT
		t.nodes[idx].rule = u32(cands[0])
		return idx
	}

	best_bit := -1
	best_cost := 1 << 30
	for bit in 0..<64 {
		ones := 0
		zeros := 0
		probe := u64(1) << uint(bit)
		for c in cands {
			r := t.rules[c]
			if r.mask & probe == 0 {
				continue
			}
			if r.value & probe != 0 {
				ones += 1
			} else {
				zeros += 1
			}
		}
		// Both sides must lose at least one candidate, or the recursion cannot terminate.
		if ones == 0 || zeros == 0 {
			continue
		}
		cost := ones
		if zeros > cost {
			cost = zeros
		}
		if cost < best_cost {
			best_cost = cost
			best_bit = bit
		}
	}
	if best_bit < 0 {
		return NO_NODE
	}

	zero_cands: [N]u16
	one_cands: [N]u16
	zc := 0
	oc := 0
	probe := u64(1) << uint(best_bit)
	for c in cands {
		r := t.rules[c]
		cares := r.mask & probe != 0
		wants_one := r.value & probe != 0
		if !cares || !wants_one {
			zero_cands[zc] = c
			zc += 1
		}
		if !cares || wants_one {
			one_cands[oc] = c
			oc += 1
		}
	}

	z := split(t, zero_cands[:zc])
	o := split(t, one_cands[:oc])
	if z == NO_NODE || o == NO_NODE {
		return NO_NODE
	}
	idx := new_node(t)
	if idx == NO_NODE {
		return NO_NODE
	}
	t.nodes[idx] = Node{zero = z, one = o, rule = NO_RULE, bit = u8(best_bit)}
	return idx
}

// build compiles `rules` into the table. Returns false for an invalid or overlapping rule set, or
// a rule set that exhausts the node pool; the table is left unbuilt on failure.
build :: proc(t: ^Table($N), rules: []Rule) -> bool {
	count := len(rules)
	if count > N || count == 0 {
		return false
	}
	t^ = {}
	for i in 0..<count {
		t.rules[i] = rules[i]
	}
	ok, _, _ := validate(t, count)
	if !ok {
		return false
	}
	cands: [N]u16
	for i in 0..<count {
		cands[i] = u16(i)
	}
	t.root = split(t, cands[:count])
	if t.root == NO_NODE {
		return false
	}
	t.flags = FLAG_BUILT
	return true
}

// match walks the read-only tree. It allocates nothing and never depends on the number of rules.
match :: proc(t: ^Table($N), word: u64) -> (u32, bool) {
	if t.flags & FLAG_BUILT == 0 {
		return 0, false
	}
	node := t.root
	for _ in 0..<len(t.nodes) {
		n := t.nodes[node]
		if n.bit == LEAF_BIT {
			if n.rule == NO_RULE {
				return 0, false
			}
			r := t.rules[n.rule]
			if word & r.mask != r.value {
				return 0, false
			}
			return r.id, true
		}
		probe := u64(1) << uint(n.bit)
		if word & probe != 0 {
			node = n.one
		} else {
			node = n.zero
		}
	}
	return 0, false
}

// linear_match is the deliberately naive reference. It is not the hot path: tests compare every
// word against it to prove the decision tree is a faithful compilation of the rule set.
linear_match :: proc(t: ^Table($N), word: u64) -> (u32, bool) {
	for i in 0..<N {
		if t.rules[i].mask == 0 {
			continue
		}
		if word & t.rules[i].mask == t.rules[i].value {
			return t.rules[i].id, true
		}
	}
	return 0, false
}
