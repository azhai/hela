#+build linux

package hela_io

// Linux backend via upstream `core:sys/posix/poll`. `poll()` is a real kernel readiness query,
// but it is O(n) over the registration table and does not report how many bytes are available,
// so `Completion.bytes` is 0 here rather than a guess. epoll / io_uring are a later swap of this
// one file; the `Completion` wire format and `event.Loop` dispatch above it do not change.

import "core:c"
import "core:sys/posix"

_backend_init :: proc(s: ^Source) -> bool {
	s.kq = -1 // poll() is stateless: no descriptor to own
	return true
}

_backend_destroy :: proc(s: ^Source) {
	s.kq = -1
}

_backend_add :: proc(s: ^Source, e: Fd_Entry) -> bool {
	return e.fd >= 0 && e.want != 0
}

_backend_remove :: proc(s: ^Source, e: Fd_Entry) -> bool {
	return e.fd >= 0
}

_backend_wait :: proc(s: ^Source, timeout_ms: int) -> int {
	s.ready = 0
	n := s.count
	if n <= 0 {
		return 0
	}
	fds: [MAX_FDS]posix.pollfd
	for i in 0..<n {
		want := posix.Poll_Event{}
		if s.entries[i].want & WANT_READ != 0 {
			want += {.IN}
		}
		if s.entries[i].want & WANT_WRITE != 0 {
			want += {.OUT}
		}
		fds[i] = posix.pollfd{fd = posix.FD(s.entries[i].fd), events = want}
	}
	r := posix.poll(raw_data(fds[:n]), posix.nfds_t(n), c.int(timeout_ms))
	if r <= 0 {
		return 0
	}
	count := 0
	for i in 0..<n {
		rev := fds[i].revents
		if rev == {} {
			continue
		}
		if count >= MAX_EVENTS {
			break
		}
		c := &s.batch[count]
		c.kind   = .Read
		c.flags  = 0
		c.tag    = s.entries[i].tag
		c.handle = u32(s.entries[i].fd)
		c.bytes  = 0 // poll() does not report a byte count
		c.udata  = u64(s.entries[i].tag)
		c.errno  = 0
		c.seq    = 0
		if .OUT in rev && !(.IN in rev) {
			c.kind = .Write
		}
		if .HUP in rev {
			c.flags |= FLAG_HUP | FLAG_EOF
		}
		if .ERR in rev || .NVAL in rev {
			c.flags |= FLAG_ERROR
			c.errno  = os_errno()
		}
		count += 1
	}
	s.ready = count
	return count
}
