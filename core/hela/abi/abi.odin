#+dialect hela
#+analysis alloc

// core:hela/abi — the runtime half of `layout_hash`.
//
// At build time the question "what shape are these bytes?" is answered twice, from one source:
// `-emit-layout` writes `layout_hash` into a manifest, and `intrinsics.layout_hash_of(T)` returns
// the same value as a compile-time constant (both read src/layout_hash.cpp). Neither of those
// helps a *running* program that is handed a buffer by somebody else — a shared-memory segment, a
// message from an older build, a file written by another machine.
//
// This package carries the answer into the process. A peer states its own fingerprint in a 24-byte
// `Stamp` before the payload is interpreted; a mismatch is a diagnosed reason (`.Layout_Drift`,
// `.Size_Mismatch`, …) instead of silently transposed fields:
//
//     buf: [STAMP_SIZE + size_of(Record)]u8
//     payload := abi.publish(buf[:], abi.stamp_of(Record))     // producer
//     rec, v := abi.share_as(buf[:], Record)                   // consumer
//     if v != .OK { /* do NOT touch rec: the bytes are not Record */ }
//
// The stamp is a fixed little-endian wire format, not the in-memory struct, so it can cross a pipe,
// a socket or a file between two builds. Both its bytes and the payload's shape are asserted at
// compile time below, which is why a change to `Stamp` cannot pass unnoticed.
package abi

import "base:intrinsics"

// The protocol magic ("HELA") and the version of the *envelope*, not of the type inside it.
// `hash` covers the type; these two cover this file's layout.
MAGIC   :: u32(0x48454c41)
VERSION :: u16(1)

// Bytes of an encoded stamp. Used as the payload offset, so keep the two in sync (asserted).
STAMP_SIZE :: 24

Stamp :: struct #explicit #align(8) {
	magic:   u32, // MAGIC
	version: u16, // VERSION of this envelope
	flags:   u16, // caller-defined, compared exactly
	hash:    u64, // intrinsics.layout_hash_of(T)
	size:    u32, // size_of(T)
	align:   u32, // align_of(T)
}

// The envelope is also the alignment contract for the payload that follows it: 24 is a multiple of
// 8, so any type aligned up to 8 starts at an aligned address right after the stamp.
#assert(size_of(Stamp) == STAMP_SIZE)
#assert(align_of(Stamp) == 8)
#assert(intrinsics.layout_padding_of(Stamp) == 0)

Stamp_Bytes :: [STAMP_SIZE]u8

// Why a stamp was rejected. Ordered by how much can be trusted: everything after `.Bad_Magic` is
// meaningless, so `verify` reports the first mismatch and stops.
Verdict :: enum u8 {
	OK,
	Bad_Magic,          // not a Hela stamp at all
	Bad_Version,        // envelope version differs: this reader may misparse even a matching hash
	Bad_Flags,          // magic and version agree, caller semantics differ
	Layout_Drift,       // same envelope, different bytes for the payload type
	Size_Mismatch,      // a drift that also changed the byte count
	Align_Mismatch,     // a drift that also changed the alignment
	Short_Buffer,       // fewer than STAMP_SIZE bytes, or too few for the payload
	Misaligned_Payload, // the buffer address cannot hold T
}

verdict_text :: proc(v: Verdict) -> string {
	switch v {
	case .OK:                 return "ok"
	case .Bad_Magic:          return "bad magic: not a Hela ABI stamp"
	case .Bad_Version:        return "bad version: the envelope layout changed"
	case .Bad_Flags:          return "bad flags: magic and version agree, semantics do not"
	case .Layout_Drift:       return "layout drift: the type's bytes changed (layout_hash differs)"
	case .Size_Mismatch:      return "size mismatch: the type grew or shrank"
	case .Align_Mismatch:     return "align mismatch: the type's alignment changed"
	case .Short_Buffer:       return "short buffer: fewer bytes than the stamp and payload need"
	case .Misaligned_Payload: return "misaligned payload: the buffer address cannot hold this type"
	}
	return "unknown"
}

// The stamp of `T` as this build sees it. Every field is a compile-time constant, so a call in a
// hot path folds away and a call in a `#assert` is free.
stamp_of :: proc($T: typeid, flags := u16(0)) -> Stamp {
	return {
		magic   = MAGIC,
		version = VERSION,
		flags   = flags,
		hash    = intrinsics.layout_hash_of(T),
		size    = u32(size_of(T)),
		align   = u32(align_of(T)),
	}
}

// Fixed little-endian encoding. Written by hand rather than by reinterpreting the struct, so the
// wire format is independent of this target's endianness and padding rules.
stamp_encode :: proc(s: Stamp) -> (b: Stamp_Bytes) {
	put_u32le(&b, 0, s.magic)
	put_u16le(&b, 4, s.version)
	put_u16le(&b, 6, s.flags)
	put_u64le(&b, 8, s.hash)
	put_u32le(&b, 16, s.size)
	put_u32le(&b, 20, s.align)
	return
}

stamp_decode :: proc(b: Stamp_Bytes) -> Stamp {
	return {
		magic   = get_u32le(b, 0),
		version = get_u16le(b, 4),
		flags   = get_u16le(b, 6),
		hash    = get_u64le(b, 8),
		size    = get_u32le(b, 16),
		align   = get_u32le(b, 20),
	}
}

// Compare what a peer sent against what this build needs. The order is deliberate: a wrong magic
// makes every other field meaningless, and a wrong version means this reader may not even know how
// to read the rest — only then is it worth pointing at the type itself.
verify :: proc(got, want: Stamp) -> Verdict {
	if got.magic != want.magic {
		return .Bad_Magic
	}
	if got.version != want.version {
		return .Bad_Version
	}
	if got.flags != want.flags {
		return .Bad_Flags
	}
	if got.hash != want.hash {
		// Same envelope, different bytes. Size/align are a strictly more specific diagnosis when
		// they changed, so prefer them in that case (a field rename is only `.Layout_Drift`).
		if got.size != want.size {
			return .Size_Mismatch
		}
		if got.align != want.align {
			return .Align_Mismatch
		}
		return .Layout_Drift
	}
	// A matching hash already implies matching size/align (both are hashed), but a hand-built or
	// corrupted stamp can still disagree; report it instead of trusting the hash alone.
	if got.size != want.size {
		return .Size_Mismatch
	}
	if got.align != want.align {
		return .Align_Mismatch
	}
	return .OK
}

// Producer side: write the stamp into the front of `buf` and hand back the payload slice that
// follows it. The buffer must be big enough; callers that need a check should size it as
// `STAMP_SIZE + size_of(T)` and assert it at compile time.
publish :: proc(buf: []u8, s: Stamp) -> []u8 {
	assert(len(buf) >= STAMP_SIZE, "publish: buffer smaller than a stamp")
	b := stamp_encode(s)
	copy(buf[0:STAMP_SIZE], b[:])
	return buf[STAMP_SIZE:]
}

// Consumer side: check the stamp, then hand back a typed view of the payload — but only when the
// verdict is `.OK`. On any other verdict the length is 0 and the pointer is nil, so a caller cannot
// accidentally interpret bytes that this build does not agree with.
share_as :: proc(buf: []u8, $T: typeid, flags := u16(0)) -> (payload: ^T, v: Verdict) {
	if len(buf) < STAMP_SIZE {
		return nil, .Short_Buffer
	}
	b: Stamp_Bytes
	copy(b[:], buf[0:STAMP_SIZE])
	got := stamp_decode(b)
	want := stamp_of(T, flags)
	v = verify(got, want)
	if v != .OK {
		return nil, v
	}

	// The stamp fields are now known to match this build, so the payload size is `size_of(T)`.
	if len(buf) < STAMP_SIZE + size_of(T) {
		return nil, .Short_Buffer
	}
	rest := buf[STAMP_SIZE:]
	addr := uintptr(&rest[0])
	if addr % align_of(T) != 0 {
		return nil, .Misaligned_Payload
	}
	return cast(^T)&rest[0], .OK
}

// Stamp only (no payload): what a handshake message needs.
share :: proc(buf: []u8) -> (s: Stamp, v: Verdict, out: []u8) {
	if len(buf) < STAMP_SIZE {
		return {}, .Short_Buffer, nil
	}
	b: Stamp_Bytes
	copy(b[:], buf[0:STAMP_SIZE])
	s = stamp_decode(b)
	if s.magic != MAGIC {
		return s, .Bad_Magic, nil
	}
	if s.version != VERSION {
		return s, .Bad_Version, nil
	}
	return s, .OK, buf[STAMP_SIZE:]
}

// Little-endian accessors over a fixed-size stamp buffer. The readers take the array by value
// (indexing a value parameter is fine, slicing it is not, and taking its address is illegal), the
// writers take a pointer because they need the caller's storage.
@(private)
put_u16le :: proc(b: ^[STAMP_SIZE]u8, at: int, v: u16) {
	b[at+0] = u8(v)
	b[at+1] = u8(v >> 8)
}

@(private)
put_u32le :: proc(b: ^[STAMP_SIZE]u8, at: int, v: u32) {
	b[at+0] = u8(v)
	b[at+1] = u8(v >> 8)
	b[at+2] = u8(v >> 16)
	b[at+3] = u8(v >> 24)
}

@(private)
put_u64le :: proc(b: ^[STAMP_SIZE]u8, at: int, v: u64) {
	for i in 0..<8 {
		b[at+i] = u8(v >> uint(8*i))
	}
}

@(private)
get_u16le :: proc(b: Stamp_Bytes, at: int) -> u16 {
	return u16(b[at+0]) | u16(b[at+1]) << 8
}

@(private)
get_u32le :: proc(b: Stamp_Bytes, at: int) -> u32 {
	return u32(b[at+0]) | u32(b[at+1]) << 8 | u32(b[at+2]) << 16 | u32(b[at+3]) << 24
}

@(private)
get_u64le :: proc(b: Stamp_Bytes, at: int) -> u64 {
	v: u64
	for i in 0..<8 {
		v |= u64(b[at+i]) << uint(8*i)
	}
	return v
}
