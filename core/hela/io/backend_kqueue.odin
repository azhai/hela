#+build darwin, netbsd, openbsd, freebsd

package hela_io

// Darwin / BSD backend. The multiplexer itself is upstream's `core:sys/kqueue`; this file only
// registers descriptors and normalizes `KEvent`s into `Completion`s. No syscall is re-declared
// here, so the fork does not get pinned to a platform ABI.

import "core:sys/posix"
import kq "core:sys/kqueue"

_backend_init :: proc(s: ^Source) -> bool {
	k, err := kq.kqueue()
	if k == -1 || err != .NONE {
		s.kq = -1
		return false
	}
	s.kq = i32(k)
	return true
}

_backend_destroy :: proc(s: ^Source) {
	if s.kq >= 0 {
		posix.close(posix.FD(s.kq))
		s.kq = -1
	}
}

_backend_add :: proc(s: ^Source, e: Fd_Entry) -> bool {
	if s.kq < 0 {
		return false
	}
	changes: [2]kq.KEvent
	n := 0
	if e.want & WANT_READ != 0 {
		changes[n] = kq.KEvent{
			ident  = uintptr(e.fd),
			filter = .Read,
			flags  = {.Add},
			udata  = cast(rawptr)uintptr(e.tag),
		}
		n += 1
	}
	if e.want & WANT_WRITE != 0 {
		changes[n] = kq.KEvent{
			ident  = uintptr(e.fd),
			filter = .Write,
			flags  = {.Add},
			udata  = cast(rawptr)uintptr(e.tag),
		}
		n += 1
	}
	if n == 0 {
		return false
	}
	_, err := kq.kevent(kq.KQ(s.kq), changes[:n], nil, nil)
	return err == .NONE
}

_backend_remove :: proc(s: ^Source, e: Fd_Entry) -> bool {
	if s.kq < 0 {
		return false
	}
	changes: [2]kq.KEvent
	n := 0
	if e.want & WANT_READ != 0 {
		changes[n] = kq.KEvent{ident = uintptr(e.fd), filter = .Read, flags = {.Delete}}
		n += 1
	}
	if e.want & WANT_WRITE != 0 {
		changes[n] = kq.KEvent{ident = uintptr(e.fd), filter = .Write, flags = {.Delete}}
		n += 1
	}
	_, err := kq.kevent(kq.KQ(s.kq), changes[:n], nil, nil)
	return err == .NONE
}

_backend_wait :: proc(s: ^Source, timeout_ms: int) -> int {
	s.ready = 0
	if s.kq < 0 || s.count == 0 {
		return 0
	}
	evs: [MAX_EVENTS]kq.KEvent
	ts := posix.timespec{
		tv_sec  = posix.time_t(timeout_ms / 1000),
		tv_nsec = i64((timeout_ms % 1000) * 1_000_000),
	}
	n, err := kq.kevent(kq.KQ(s.kq), nil, evs[:], &ts)
	if err != .NONE {
		return 0
	}
	count := int(n)
	if count > MAX_EVENTS {
		count = MAX_EVENTS
	}
	for i in 0..<count {
		ev := &evs[i]
		c  := &s.batch[i]
		c.kind   = .Read
		if ev.filter == .Write {
			c.kind = .Write
		}
		c.flags  = 0
		c.tag    = u16(uintptr(ev.udata))
		c.handle = u32(ev.ident)
		c.bytes  = i64(ev.data)
		c.udata  = u64(uintptr(ev.udata))
		c.errno  = 0
		c.seq    = 0
		if .EOF in ev.flags {
			c.flags |= FLAG_EOF
		}
		if .Error in ev.flags {
			c.flags |= FLAG_ERROR
			c.errno  = i32(ev.data)
		}
	}
	s.ready = count
	return count
}
