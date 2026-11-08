#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !linux

package hela_io

// Windows / other targets: no backend yet. This is an explicit, compiling "not supported"
// rather than a silent no-op, so `source_init` fails and `FULLY_SUPPORTED` tells the caller why.
// IOCP (Windows) and io_uring (a faster Linux path) are separate future backends; the common
// layer in `io.odin` does not change when they land.

FULLY_SUPPORTED :: false

make_pipe :: proc() -> (r: i32, w: i32, ok: bool) {
	return -1, -1, false
}

read_fd :: proc(fd: i32, buf: []u8) -> int {
	return -1
}

write_fd :: proc(fd: i32, buf: []u8) -> int {
	return -1
}

close_fd :: proc(fd: i32) {}

os_errno :: proc() -> i32 {
	return 0
}

_backend_init :: proc(s: ^Source) -> bool {
	s.kq = -1
	return false
}

_backend_destroy :: proc(s: ^Source) {
	s.kq = -1
}

_backend_add :: proc(s: ^Source, e: Fd_Entry) -> bool {
	return false
}

_backend_remove :: proc(s: ^Source, e: Fd_Entry) -> bool {
	return false
}

_backend_wait :: proc(s: ^Source, timeout_ms: int) -> int {
	s.ready = 0
	return 0
}
