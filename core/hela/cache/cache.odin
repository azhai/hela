#+dialect hela
#+analysis alloc
#+analysis sharing

// Sharded, fixed-capacity cache with absolute-deadline TTL and generation-based eviction.
//
// From oboe's cache: `hash -> packed slot` (generation in the high bits), a per-bucket chunk that
// wraps by bumping the generation, lazy expiry, and `get_into` which copies into the caller's
// buffer instead of allocating an intermediate value. Hela's contribution is that the per-shard
// hot field is *declared* to be on its own cache line, and the compiler checks it.
//
// Deliberately simpler than oboe: no map, no zlib snapshot, no big-value FIFO. A map would hide
// allocations (and rehashes) inside a hot path; open addressing over a fixed array is one `[]`
// whose size is known at boot.
package cache

import "core:sync"

KEY_MAX    :: 16
VALUE_MAX  :: 32
PROBE_MAX  :: 8
Cache_Line :: 64

Entry :: struct {
	hash:       u64, // 0 means empty; also the full key fingerprint
	expires:    i64, // absolute nanoseconds; 0 means "never"
	generation: u32,
	key_len:    u8,
	val_len:    u8,
	key:        [KEY_MAX]u8,
	value:      [VALUE_MAX]u8,
}

// Each shard starts on its own line, and the only field another thread might poll is `version`.
// `#align(Cache_Line)` on the struct also makes `size_of(Shard)` a multiple of a cache line, so
// consecutive shards cannot share one.
Shard :: struct #align(Cache_Line) {
	#atomic #share(owner) version: u64,
	entries:                      []Entry,
	mask:                         u64,
	generation:                   u32,
	count:                        int,
}

#assert(size_of(Shard) % Cache_Line == 0)
#assert(offset_of_by_string(Shard, "version") == 0)

Cache :: struct {
	shards: []Shard,
}

FNV_BASIS :: 0xcbf29ce484222325
FNV_PRIME :: 0x100000001b3

// fnv1a is inline, allocation-free, and stable across runs (unlike a randomized hash seed).
fnv1a :: proc(data: []u8) -> u64 {
	h := u64(FNV_BASIS)
	for b in data {
		h = (h ~ u64(b)) * u64(FNV_PRIME)
	}
	return h
}

// init requires power-of-two shard and entry counts, so both wraps are masks.
init :: proc(c: ^Cache, shard_count: int, entries_per_shard: int, allocator := context.allocator) -> bool {
	if shard_count <= 0 || shard_count & (shard_count - 1) != 0 {
		return false
	}
	if entries_per_shard <= 0 || entries_per_shard & (entries_per_shard - 1) != 0 {
		return false
	}
	c.shards = make([]Shard, shard_count, allocator)
	if c.shards == nil {
		return false
	}
	for &s in c.shards {
		s.entries = make([]Entry, entries_per_shard, allocator)
		if s.entries == nil {
			return false
		}
		s.mask = u64(entries_per_shard - 1)
		s.generation = 1
	}
	return true
}

destroy :: proc(c: ^Cache, allocator := context.allocator) {
	for &s in c.shards {
		delete(s.entries, allocator)
	}
	delete(c.shards, allocator)
	c.shards = nil
}

shard_for :: proc(c: ^Cache, hash: u64) -> ^Shard {
	return &c.shards[int(hash & u64(len(c.shards) - 1))]
}

// set inserts or replaces. `ttl_ns == 0` means no expiry. Returns false when the key/value is too
// large or the probe window is full (in which case no partial state is written).
set :: proc(c: ^Cache, key, value: []u8, ttl_ns, now: i64) -> bool {
	if len(key) == 0 || len(key) > KEY_MAX || len(value) > VALUE_MAX || len(c.shards) == 0 {
		return false
	}
	h := fnv1a(key)
	s := shard_for(c, h)
	start := int((h >> 8) & s.mask)
	victim := -1
	for probe in 0..<PROBE_MAX {
		e := &s.entries[(start + probe) & int(s.mask)]
		if e.hash == 0 {
			victim = (start + probe) & int(s.mask)
			break
		}
		if e.hash == h && e.generation == s.generation && int(e.key_len) == len(key) {
			same := true
			for i in 0..<len(key) {
				if e.key[i] != key[i] {
					same = false
					break
				}
			}
			if same {
				victim = (start + probe) & int(s.mask)
				break
			}
		}
		if e.expires != 0 && e.expires <= now {
			victim = (start + probe) & int(s.mask)
			break
		}
	}
	if victim < 0 {
		return false
	}
	e := &s.entries[victim]
	was_empty := e.hash == 0
	e.hash = h
	e.generation = s.generation
	e.key_len = u8(len(key))
	e.val_len = u8(len(value))
	e.expires = 0
	if ttl_ns > 0 {
		e.expires = now + ttl_ns
	}
	for i in 0..<len(key) {
		e.key[i] = key[i]
	}
	for i in 0..<len(value) {
		e.value[i] = value[i]
	}
	if was_empty {
		s.count += 1
	}
	// Release: a reader that sees the new version also sees the entry writes above.
	sync.atomic_add_explicit(&s.version, 1, .Release)
	return true
}

// get_into copies straight into `dst`. Returns the byte count, -1 for a miss/expiry, or 0 when
// `dst` is too small. No intermediate []u8 is ever created.
get_into :: proc(c: ^Cache, key: []u8, dst: []u8, now: i64) -> int {
	if len(key) == 0 || len(key) > KEY_MAX || len(c.shards) == 0 {
		return -1
	}
	h := fnv1a(key)
	s := shard_for(c, h)
	version := sync.atomic_load_explicit(&s.version, .Acquire)
	start := int((h >> 8) & s.mask)
	for probe in 0..<PROBE_MAX {
		e := &s.entries[(start + probe) & int(s.mask)]
		if e.hash != h || e.generation != s.generation || int(e.key_len) != len(key) {
			continue
		}
		same := true
		for i in 0..<len(key) {
			if e.key[i] != key[i] {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		if e.expires != 0 && e.expires <= now {
			return -1
		}
		if len(dst) < int(e.val_len) {
			return 0
		}
		for i in 0..<int(e.val_len) {
			dst[i] = e.value[i]
		}
		// A concurrent writer bumped the version while we read: report a miss rather than a
		// torn value. The caller decides whether to retry.
		if sync.atomic_load_explicit(&s.version, .Acquire) != version {
			return -1
		}
		return int(e.val_len)
	}
	return -1
}

// drop_generation invalidates every entry in a shard without touching a byte of their data:
// generation mismatch is enough. This is oboe's chunk wrap, done in one store.
drop_generation :: proc(c: ^Cache, shard_index: int) -> bool {
	if shard_index < 0 || shard_index >= len(c.shards) {
		return false
	}
	s := &c.shards[shard_index]
	s.generation += 1
	if s.generation == 0 {
		s.generation = 1
	}
	s.count = 0
	sync.atomic_add_explicit(&s.version, 1, .Release)
	return true
}

// expire clears expired entries. Lazy checks in get_into already hide them; this reclaims slots.
expire :: proc(c: ^Cache, now: i64) -> int {
	removed := 0
	for &s in c.shards {
		for &e in s.entries {
			if e.hash != 0 && e.expires != 0 && e.expires <= now {
				e.hash = 0
				s.count -= 1
				removed += 1
			}
		}
	}
	return removed
}
