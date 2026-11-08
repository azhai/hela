#+build darwin, netbsd, openbsd, freebsd, linux

package hela_io

import "core:c"
import "core:sys/posix"

// True on every POSIX target we have a backend for. On Windows the stub file defines this as
// false, so callers can tell "no events" from "no I/O source at all".
FULLY_SUPPORTED :: true

// Thin fd helpers shared by both POSIX backends. Tests use these instead of importing platform
// packages, which keeps the Hela surface identical on kqueue and poll targets.
make_pipe :: proc() -> (r: i32, w: i32, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return -1, -1, false
	}
	return i32(fds[0]), i32(fds[1]), true
}

read_fd :: proc(fd: i32, buf: []u8) -> int {
	if fd < 0 || len(buf) == 0 {
		return 0
	}
	return int(posix.read(posix.FD(fd), raw_data(buf), c.size_t(len(buf))))
}

write_fd :: proc(fd: i32, buf: []u8) -> int {
	if fd < 0 || len(buf) == 0 {
		return 0
	}
	return int(posix.write(posix.FD(fd), raw_data(buf), c.size_t(len(buf))))
}

close_fd :: proc(fd: i32) {
	if fd >= 0 {
		posix.close(posix.FD(fd))
	}
}

os_errno :: proc() -> i32 {
	return i32(posix.errno())
}
