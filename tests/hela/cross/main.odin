#+dialect hela

// Cross-target ABI pin.
//
// `tests/hela/abi` pins layouts for the *host* and its assertions spell out 64-bit numbers, so a
// 32-bit target cannot even compile it. This package is the complement: every assertion here holds
// on every target, and `tests/hela/run.sh` checks the package under several `-target:` values,
// diffs each one against a committed `golden.<target>.hash`, then feeds all manifests to
// `hela-layout --stable`.
//
// The point is not "four targets compile" but "which bytes may be put on the wire":
//
//   * `Fixed_Wire` / `Aligned_Counters` must be STABLE — same layout_hash everywhere.
//   * `Unpinned_Wire` / `Native_Record` must DRIFT — they let a target decide an alignment or a
//     pointer width. A report with no DRIFT line would mean the gate can no longer detect drift.
//
// The subtle one is `Unpinned_Wire`: every field is pinned with `#offset`, yet on i386/wasm32 a
// `u64` field aligns to 4 instead of 8, so the *struct's* alignment drops and its hash changes.
// Pinning offsets is not enough; `Fixed_Wire` adds `#align(8)` and is stable. This is exactly the
// kind of fact a model cannot infer from source text — the compiler has to export it.
package cross

import "base:intrinsics"

// A wire format: 32 bytes, no padding, and an explicitly pinned alignment.
Fixed_Wire :: struct #explicit #align(8) {
	#offset(0)  tag:   u16,
	#offset(2)  flags: u16,
	#offset(4)  seq:   u32,
	#offset(8)  stamp: u64,
	#offset(16) key:   u64,
	#offset(24) crc:   u32,
	#offset(28) _:     [4]u8,
}
#assert(size_of(Fixed_Wire) == 32)
#assert(align_of(Fixed_Wire) == 8)
#assert(offset_of_by_string(Fixed_Wire, "stamp") == 8)
#assert(intrinsics.layout_padding_of(Fixed_Wire) == 0)

// Control for the above: identical bytes on a 64-bit host, but the alignment is left to the
// target. `#offset` fixes *where* a field starts, not what the whole struct aligns to.
Unpinned_Wire :: struct #explicit {
	#offset(0)  tag:   u16,
	#offset(2)  flags: u16,
	#offset(4)  seq:   u32,
	#offset(8)  stamp: u64,
	#offset(16) key:   u64,
	#offset(24) crc:   u32,
	#offset(28) _:     [4]u8,
}
#assert(size_of(Unpinned_Wire) == 32)
#assert(offset_of_by_string(Unpinned_Wire, "stamp") == 8)
#assert(intrinsics.layout_padding_of(Unpinned_Wire) == 0)

// A cache-line contract is target independent: field-level `#align(64)` fixes both the offsets
// and the struct alignment, so no target gets a vote.
Aligned_Counters :: struct {
	#align(64) #atomic #share(producer) head: u64,
	#align(64) #atomic #share(consumer) tail: u64,
}
#assert(size_of(Aligned_Counters) == 128)
#assert(align_of(Aligned_Counters) == 64)
#assert(offset_of_by_string(Aligned_Counters, "tail") == 64)

// A native record: pointer-sized fields are supposed to follow the target. Never use this as a
// wire format. Its drift on 32-bit targets is what proves the gate is live.
Native_Record :: struct {
	owner: rawptr,
	index: int,
	tag:   u8,
}
#assert(offset_of_by_string(Native_Record, "index") == size_of(rawptr))
