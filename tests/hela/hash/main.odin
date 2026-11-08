#+dialect hela
#+analysis sharing
// `layout_hash_of(T)` is the manifest's `layout_hash` as a compile-time constant. Same function
// computes both (src/layout_hash.cpp), so this package can prove three things at once:
//
//   1. two types with the same bytes hash the same, even across names/annotations;
//   2. one changed byte, bit range or array shape changes the hash;
//   3. the manifest and the intrinsic agree for *every* type here (run.sh diffs them).
//
// Because the value is a constant, an ABI pin needs no golden file: the `#assert`s below are the
// gate. `core:hela/abi` then carries the same number into a running process.

package main

import "base:intrinsics"
import "core:fmt"
import "core:os"

import "core:hela/abi"

// --- the same bytes, written differently ------------------------------------------------------

Wire :: struct #explicit {
	kind: u32,
	len:  u32,
}

// A different name for the same shape. The hash covers the bytes, not the identifier: this is what
// makes two independently evolved `Header`/`Message_Prefix` types interchangeable on the wire.
Wire_Same_Bytes :: struct #explicit {
	kind: u32,
	len:  u32,
}

// Same size and alignment, different layout: `len` now owns the first four bytes.
Wire_Swapped :: struct #explicit {
	len:  u32,
	kind: u32,
}

// Padding that happens to be named occupies bytes but is not part of the interface, so `_` fields
// are skipped: the hand-written and the declared-padding spellings share one hash.
//
// The `#align(64)` is not decoration. `#split(64)` means "one field per 64-byte line", which
// *also* aligns the struct to 64; `#explicit` + `_: [56]u8` alone is a 64-byte struct with natural
// alignment 8. Same size, same offsets — and a different hash, because alignment decides the
// stride of `[N]T` and therefore where the bytes go. `Padded_Loose` is that case, kept as a
// negative so the distinction is a test rather than a comment.
Padded :: struct #align(64) #explicit {
	n: u64,
	_: [56]u8,
}

Padded_Split :: struct #split(64) {
	n: u64,
}

Padded_Loose :: struct #explicit {
	n: u64,
	_: [56]u8,
}

// --- arrays: shape is part of the layout ------------------------------------------------------

Vec3 :: struct #explicit {
	x, y, z: f32,
	_: f32,
}

// A block-transposed array and the `#soa` spelling it desugars to: same bytes, same hash.
Aosoa :: #aosoa[8][32]Vec3
Aosoa_Explicit :: [4]#soa[8]Vec3

// Both 64 bytes; they index differently, so they are not the same layout.
Flat :: [8]u64
Nested :: [2][4]u64

// --- bit fields: the bit range is part of the layout -------------------------------------------

Bits_A :: bit_field u16 {
	lo: u8 | 3,
	hi: u8 | 5,
}

Bits_B :: bit_field u16 {
	lo: u8 | 4,
	hi: u8 | 4,
}

// `#share`/`#atomic` describe how a field is accessed, not where it lives: they must not move the
// hash. `#align` does move bytes, so it moves the hash too (implicitly, through size/align).
Hot :: struct {
	#align(64) #share(writer) #atomic x: u64,
	#align(64) y: u64,
}

Hot_Plain :: struct {
	#align(64) #share(writer) x: u64,
	#align(64) y: u64,
}

// The record the ABI handshake below actually ships. `#align(8)` is what makes its hash identical
// on 32-bit targets too: without it `linux_i386` drops `u64`'s alignment to 4, which changes the
// struct alignment, which is part of the fingerprint (see 17-m21-cross-target.md).
Record :: struct #align(8) #explicit {
	seq:     u64,
	kind:    u32,
	len:     u32,
	payload: [16]u8,
}

#assert(size_of(Wire) == 8)
#assert(size_of(Padded) == 64)
#assert(size_of(Padded_Split) == 64)
#assert(align_of(Padded) == 64 && align_of(Padded_Split) == 64)
// The loose spelling gets whatever alignment `u64` has on this target (8 on 64-bit, 4 on
// `linux_i386`); either way it is not 64, which is the whole point of keeping it as a negative.
#assert(align_of(Padded_Loose) != 64)
#assert(size_of(Aosoa) == 512)
#assert(size_of(Record) == 32)

// 1. Same bytes ⇒ same hash, regardless of the name.
#assert(intrinsics.layout_hash_of(Wire) == intrinsics.layout_hash_of(Wire_Same_Bytes))
// 2. Different arrangement ⇒ different hash.
#assert(intrinsics.layout_hash_of(Wire) != intrinsics.layout_hash_of(Wire_Swapped))
// 3. Named padding is invisible to the hash — once the alignment agrees.
#assert(intrinsics.layout_hash_of(Padded) == intrinsics.layout_hash_of(Padded_Split))
#assert(intrinsics.layout_hash_of(Padded) != intrinsics.layout_hash_of(Padded_Loose))
// 4. `#aosoa[W][N]T` == `[N/W]#soa[W]T`, also in the hash.
#assert(intrinsics.layout_hash_of(Aosoa) == intrinsics.layout_hash_of(Aosoa_Explicit))
// 5. Array shape is part of the layout, even at equal size.
#assert(intrinsics.layout_hash_of(Flat) != intrinsics.layout_hash_of(Nested))
// 6. Moving a bit boundary moving the hash, without changing a single byte of size/align.
#assert(intrinsics.layout_hash_of(Bits_A) != intrinsics.layout_hash_of(Bits_B))
// 7. `#atomic`/`#share` are metadata; `Hot` and `Hot_Plain` occupy the same bytes.
#assert(intrinsics.layout_hash_of(Hot) == intrinsics.layout_hash_of(Hot_Plain))

// 8. ABI pins. These are the same numbers the manifest reports for `main::Wire` and
//    `main::Record`; run.sh diffs the two so a silent change to either side fails the build.
WIRE_HASH   :: 0x2873f36e4697a61d
RECORD_HASH :: 0x520c6c5f88aba6aa
#assert(intrinsics.layout_hash_of(Wire) == WIRE_HASH)
#assert(intrinsics.layout_hash_of(Record) == RECORD_HASH)

// The intrinsic is a constant wherever it is spelled, including inside a generic procedure.
hash_of :: proc($T: typeid) -> u64 {
	return intrinsics.layout_hash_of(T)
}

// (A generic wrapper cannot be folded into a global `#assert` — it needs a context — so that
// equivalence is checked at run time below instead.)

fail_count: int

expect :: proc(cond: bool, what: string) {
	if !cond {
		fmt.eprintfln("FAIL: %s", what)
		fail_count += 1
	}
}

// One line per type, in the shape `hela-layout --hashes` prints, so run.sh can diff the manifest
// against what the compiler folded into this binary.
emit :: proc(name: string, h: u64) {
	fmt.printfln("%s\t%016x", name, h)
}

main :: proc() {
	fmt.println("-- layout_hash_of vs. the accepted values --")

	emit("Wire",            intrinsics.layout_hash_of(Wire))
	emit("Wire_Same_Bytes", intrinsics.layout_hash_of(Wire_Same_Bytes))
	emit("Wire_Swapped",    intrinsics.layout_hash_of(Wire_Swapped))
	emit("Padded",          intrinsics.layout_hash_of(Padded))
	emit("Padded_Split",    intrinsics.layout_hash_of(Padded_Split))
	emit("Padded_Loose",    intrinsics.layout_hash_of(Padded_Loose))
	emit("Vec3",            intrinsics.layout_hash_of(Vec3))
	emit("Aosoa",           intrinsics.layout_hash_of(Aosoa))
	emit("Aosoa_Explicit",  intrinsics.layout_hash_of(Aosoa_Explicit))
	emit("Flat",            intrinsics.layout_hash_of(Flat))
	emit("Nested",          intrinsics.layout_hash_of(Nested))
	emit("Bits_A",          intrinsics.layout_hash_of(Bits_A))
	emit("Bits_B",          intrinsics.layout_hash_of(Bits_B))
	emit("Hot",             intrinsics.layout_hash_of(Hot))
	emit("Hot_Plain",       intrinsics.layout_hash_of(Hot_Plain))
	emit("Record",          intrinsics.layout_hash_of(Record))

	fmt.println("-- runtime ABI handshake --")

	expect(hash_of(Wire) == intrinsics.layout_hash_of(Wire), "a generic wrapper folds to the same hash")
	expect(hash_of(Record) == intrinsics.layout_hash_of(Record), "a generic wrapper folds to the same hash")

	// The stamp must describe this build exactly.
	want := abi.stamp_of(Record)
	expect(want.hash == intrinsics.layout_hash_of(Record), "stamp.hash is layout_hash_of(Record)")
	expect(want.size == u32(size_of(Record)), "stamp.size is size_of(Record)")
	expect(want.align == u32(align_of(Record)), "stamp.align is align_of(Record)")
	expect(want.version == abi.VERSION && want.magic == abi.MAGIC, "stamp carries the envelope id")

	// Encode → decode is lossless, byte for byte.
	raw := abi.stamp_encode(want)
	back := abi.stamp_decode(raw)
	expect(back == want, "stamp encode/decode round-trips")
	expect(abi.verify(back, want) == .OK, "a stamp verifies against itself")
	expect(len(raw) == abi.STAMP_SIZE, "a stamp is STAMP_SIZE bytes on the wire")

	// Producer publishes stamp + payload; consumer gets a typed view back.
	buf: [abi.STAMP_SIZE + size_of(Record)]u8
	body := abi.publish(buf[:], want)
	expect(len(body) == size_of(Record), "publish returns the payload slice after the stamp")
	prod := cast(^Record)&body[0]
	prod^ = Record{seq = 1234567, kind = 7, len = 3}
	for i in 0 ..< len(prod.payload) {
		prod.payload[i] = u8(i + 1)
	}

	got, v := abi.share_as(buf[:], Record)
	expect(v == .OK, "share_as accepts a stamp this build wrote")
	expect(got != nil, "a valid share returns a pointer")
	if got != nil {
		expect(got.seq == 1234567, "payload survives publish/share_as (seq)")
		expect(got.kind == 7 && got.len == 3, "payload survives publish/share_as (kind/len)")
		expect(got.payload[15] == 16, "payload survives publish/share_as (bytes)")
	}

	// Truncation is caught before any pointer is handed out.
	_, short := abi.share_as(buf[: abi.STAMP_SIZE - 1], Record)
	expect(short == .Short_Buffer, "a buffer smaller than a stamp is Short_Buffer")
	_, short = abi.share_as(buf[: abi.STAMP_SIZE], Record)
	expect(short == .Short_Buffer, "a stamp without its payload is Short_Buffer")

	// Every way a peer can disagree, reported as a distinct reason rather than as garbage.
	drift := want
	drift.hash += 1
	expect(abi.verify(drift, want) == .Layout_Drift, "a different hash is Layout_Drift")

	drift = want
	drift.hash += 1
	drift.size += 8
	expect(abi.verify(drift, want) == .Size_Mismatch, "hash+size is Size_Mismatch")

	drift = want
	drift.hash += 1
	drift.align += 8
	expect(abi.verify(drift, want) == .Align_Mismatch, "hash+align is Align_Mismatch")

	drift = want
	drift.magic = 0
	expect(abi.verify(drift, want) == .Bad_Magic, "a wrong magic is Bad_Magic")

	drift = want
	drift.version += 1
	expect(abi.verify(drift, want) == .Bad_Version, "a wrong version is Bad_Version")

	drift = want
	drift.flags += 1
	expect(abi.verify(drift, want) == .Bad_Flags, "a wrong flag is Bad_Flags")

	// A peer that speaks about another type: same size, same align, different bytes. Its own
	// buffer, so the Record stamp above stays intact for the checks that follow.
	wire_buf: [abi.STAMP_SIZE + size_of(Wire)]u8
	_ = abi.publish(wire_buf[:], abi.stamp_of(Wire_Swapped))
	_, v = abi.share_as(wire_buf[:], Wire)
	expect(v == .Layout_Drift, "a stamp for another 8-byte type is Layout_Drift, not size drift")
	swapped, sv := abi.share_as(wire_buf[:], Wire_Swapped)
	expect(sv == .OK && swapped != nil, "the same buffer is accepted for the type it describes")

	// Nothing is handed out unless the verdict is OK: no nil check can be forgotten.
	expect(abi.verify(abi.stamp_decode(raw), want) == .OK, "verify agrees with decode")
	s, v2, tail := abi.share(buf[:])
	expect(v2 == .OK, "share accepts a valid envelope")
	expect(tail != nil && len(tail) == size_of(Record), "share returns the payload slice")
	expect(s.hash == want.hash, "share decodes the hash")
	expect(s.magic == abi.MAGIC && s.version == abi.VERSION, "share decodes the envelope id")

	// The same bytes through a file: what a stale build left on disk is rejected, not interpreted.
	dir := "."
	if len(os.args) > 1 {
		dir = os.args[1]
	}
	path := fmt.tprintf("%s/hash_artifact.bin", dir)
	defer os.remove(path)

	if err := os.write_entire_file(path, buf[:]); err != nil {
		fmt.eprintfln("FAIL: write artifact: %v", err)
		fail_count += 1
	} else if data, read_err := os.read_entire_file_from_path(path, context.allocator); read_err != nil {
		fmt.eprintfln("FAIL: read artifact: %v", read_err)
		fail_count += 1
	} else {
		defer delete(data)
		from_file, fv := abi.share_as(data, Record)
		expect(fv == .OK, "an artifact written by this build verifies")
		if from_file != nil {
			expect(from_file.seq == 1234567, "artifact payload survives a file round-trip")
		}

		// Corrupt the stored hash the way a layout change would, and re-read.
		corrupt := make([]u8, len(data))
		defer delete(corrupt)
		copy(corrupt, data)
		corrupt[8] = corrupt[8] ~ 0x01
		_, cv := abi.share_as(corrupt, Record)
		expect(cv == .Layout_Drift, "a stale artifact is Layout_Drift, not garbage data")
	}

	if fail_count > 0 {
		fmt.eprintfln("hash tests: %d failure(s)", fail_count)
		os.exit(1)
	}
	fmt.println("hash tests: ok")
}
