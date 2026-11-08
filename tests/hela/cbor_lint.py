#!/usr/bin/env python3
"""Structural lint for `odin check -emit-layout:cbor` manifests.

Why this exists: the CBOR writer emits maps with an explicit pair count, and that count is written
by hand (`sw_map(&w, 7)` in src/layout_writer.cpp). JSON tolerates a wrong count -- the parser keeps
reading -- so a miscount is invisible until something decodes the CBOR and either loses the last
entries or walks off the end. Every version bump that adds a root key (v6 `target`/`pointer_size`,
v8 `cache_line_explicit`) touches exactly those numbers.

This walks the whole document without decoding values: it checks that each map's declared pair count
is exactly what follows, and that the document ends where the root says it ends. A miscount shows up
as a structural failure rather than as a decoder's guess.

Usage: cbor_lint.py <manifest.cbor>
"""

import sys


class Bad(Exception):
    pass


def head(b, i):
    if i >= len(b):
        raise Bad("truncated header at %d" % i)
    ib = b[i]
    i += 1
    major, info = ib >> 5, ib & 0x1F
    if info < 24:
        return major, info, i
    if info == 24:
        return major, b[i], i + 1
    if info == 25:
        return major, int.from_bytes(b[i:i + 2], "big"), i + 2
    if info == 26:
        return major, int.from_bytes(b[i:i + 4], "big"), i + 4
    if info == 27:
        return major, int.from_bytes(b[i:i + 8], "big"), i + 8
    if info == 31:
        raise Bad("indefinite-length items are not part of this writer's dialect")
    raise Bad("reserved additional-info %d at %d" % (info, i - 1))


def walk(b, i, path="/", stats=None):
    major, n, i = head(b, i)
    if major in (0, 1):  # unsigned / negative int
        return i
    if major in (2, 3):  # byte / text string
        end = i + n
        if end > len(b):
            raise Bad("%s: string of %d bytes at %d overruns the document" % (path, n, i))
        return end
    if major == 4:
        if stats is not None:
            stats["arrays"] += 1
        for k in range(n):
            i = walk(b, i, "%s[%d]" % (path, k), stats)
        return i
    if major == 5:
        if stats is not None:
            stats["maps"] += 1
            stats["pairs"] += n
        for k in range(n):
            key, i = read_key(b, i, path)
            i = walk(b, i, "%s%s/" % (path, key), stats)
        return i
    if major == 7:  # simple values: the writer only emits booleans
        if n not in (20, 21):
            raise Bad("%s: unexpected simple value %d (only true/false are written)" % (path, n))
        return i
    raise Bad("%s: major type %d is not part of this writer's dialect" % (path, major))


def read_key(b, i, path):
    major, n, i = head(b, i)
    if major != 3:
        raise Bad("%s: map key is not a text string (major %d)" % (path, major))
    end = i + n
    if end > len(b):
        raise Bad("%s: map key overruns the document" % path)
    return b[i:end].decode("utf-8", "replace"), end


def decode_header(path):
    """Read the root map's keys and the scalar-looking ones among them."""
    with open(path, "rb") as f:
        b = f.read()
    stats = {"maps": 0, "arrays": 0, "pairs": 0}
    end = walk(b, 0, "/", stats)
    if end != len(b):
        raise Bad("document is %d bytes but the root claims %d (a map count is too small)"
                  % (len(b), end))

    major, n, i = head(b, 0)
    if major != 5:
        raise Bad("root is not a map")
    header = {}
    for _ in range(n):
        key, i = read_key(b, i, "/")
        kmajor, kn, j = head(b, i)
        if kmajor == 0:
            header[key] = kn
        elif kmajor == 1:
            header[key] = -1 - kn
        elif kmajor == 7:
            header[key] = kn == 21
        elif kmajor in (2, 3):
            header[key] = b[j:j + kn].decode("utf-8", "replace")
        i = walk(b, i, "/" + key)
    return header, stats


def main(argv):
    if len(argv) != 2:
        print("usage: cbor_lint.py <manifest.cbor>", file=sys.stderr)
        return 2
    try:
        header, stats = decode_header(argv[1])
    except Bad as e:
        print("cbor-lint: FAIL: %s" % e, file=sys.stderr)
        return 1
    for key in ("version", "target", "pointer_size", "cache_line", "cache_line_explicit"):
        if key not in header:
            print("cbor-lint: FAIL: root is missing '%s'" % key, file=sys.stderr)
            return 1
    if header["cache_line_explicit"] not in (True, False):
        print("cbor-lint: FAIL: cache_line_explicit is not a boolean", file=sys.stderr)
        return 1
    print("cbor-lint: ok: %d map(s), %d pair(s), version %d, cache_line %d B (%s)"
          % (stats["maps"], stats["pairs"], header["version"], header["cache_line"],
             "declared" if header["cache_line_explicit"] else "default"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
