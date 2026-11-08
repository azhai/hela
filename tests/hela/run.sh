#!/usr/bin/env sh
# Hela layout regression suite:
#   1. compile-time layout assertions (#assert + intrinsics.layout_*)
#   2. the manifest is byte-for-byte deterministic across runs
#   3. hela-layout renders bytes, cache lines and padding
#   4. `struct #explicit` rejects implicit padding, and so do the `#split` misuse cases
#   5. `-emit-layout-for` narrows the manifest to the named files/directories
#   6. `-layout-cache-line` moves the cache-line boundaries, in the manifest *and* in the intrinsic
#   7. ABI gate: the layout hashes of tests/hela/abi match the committed golden file
#   8. cross-target ABI gate: manifest v7 records the target, five `golden.<target>.hash` files
#      pin the per-target bytes, and `--stable` separates wire-safe types from drifting ones
#   9. `core:hela/ring`: layout assertions, two-thread correctness, false sharing measured
#   10. `struct #split(N)`: the same bytes as hand-written padding, checked at compile time and again
#      at run time
#  11. field-level `#align(N)`: the same bytes as hand-written padding, in arrays too, and the
#      manifest reports the declared alignment
#  12. `#aosoa[W][N]T`: blocks of W elements, the same bytes as `[N/W]#soa[W]T`
#  13. `#share(label)` + `#+analysis sharing`: two writers on one cache line is a compile error,
#      and the line size the analysis uses is the same `-layout-cache-line` the manifest uses
#  14. field-level `#offset(N)`: an absolute byte position, which is what a wire header or a
#      register map means; `#explicit` accepts the gaps a pin declares
#  15. `hela-layout --waste`: the padding each type carries, ranked, with declared padding kept
#      apart from padding reordering could remove
#  16. `#atomic` field prefix: a checked concurrency contract, exported as field metadata
#  17. `hela-layout --contract`: one owner + atomics per cache line, machine-readable ownership
#  18. `#+analysis alloc`: no implicit `context.allocator` in a Hela hot path, plus escape hatches
#  19. bit-segment masks are compiler constants (`layout_bit_mask_of` /
#      `layout_bit_encode_of`), exported by manifest v7 and rendered by `--bits`
#  20. `core:hela/pattern`: derived rules, overlap rejection and a reusable
#      bit-decision table, checked exhaustively against an independent oracle
#  21. `core:hela/flow`: a reusable backpressure Gate + Table, with the Spin/Pump/Reject
#      policy checked exhaustively on a thread-free topology model
#  22. every `core:hela/*` package compiles under the same strict vet flags CI uses
#  23. end-to-end runtime stack: mem / queue litmus / msg / event DST / supervise / cache / log /
#      bench, with compile-time layout assertions and run-time behaviour checks
#  24. `core:hela/io`: a real kernel event source (pipe -> kqueue/poll -> Completion ->
#      event.Loop), with locked wire-format bytes, deterministic dispatch, deregistration and EOF
#  25. `core:hela/exec`: a thread-per-core / shared-nothing runtime over an N x N SPSC mailbox
#      matrix, now driven by those real I/O completions; 4096-delivery litmus with a mailbox
#      capacity (8) far below the burst (256) — only the M23 pump avoids the seed deadlock —
#      plus per-worker cache + event loop + supervision + log and an exported ownership contract
#  26. array elements: a writer-bearing type must be a whole cache line, or `[N]T` puts a writer
#      from element i and a writer from element i+1 on one line; the rule is a warning, and the
#      1.4-1.8x it is worth is measured here
#  27. `layout_hash_of(T)`: the manifest's `layout_hash` as a compile-time constant, diffed
#      type-by-type against the emitted manifest, pinned by `#assert` with no golden file, and
#      carried into a running process by `core:hela/abi` (stamp + verify + publish/share_as)
#  28. the memory hierarchy of the machine: dependent-load latency per level, streaming read and
#      copy bandwidth, aggregate multi-thread bandwidth, one-pass vs two-pass SIMD scanning, and
#      (full mode only) read(2) vs mmap vs the device itself
#  29. `HELA_TSAN=1` additionally checks the MPMC queue, the I/O source and the exec runtime under
#      the thread sanitizer
#
# Every Hela file opts in with `#+dialect hela` at the top; the extension stays `.odin`.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ODIN=${ODIN:-$ROOT/odin}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[1/29] compile-time layout assertions"
# Same flag set CI uses for `tests/core`, so these packages could be wired into CI unchanged.
"$ODIN" check "$HERE/layout"  -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/abi"    -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -no-entry-point > /dev/null
"$ODIN" check "$HERE/cross"  -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -no-entry-point > /dev/null
"$ODIN" check "$HERE/ring"    -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/split"   -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/field_align" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/aosoa" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/sharing" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/field_offset" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/atomic" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/alloc" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/runtime" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/exec" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/io" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/pattern" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/hash" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
"$ODIN" check "$HERE/membw" -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do -no-bounds-check > /dev/null

echo "[2/29] manifest is deterministic, and its CBOR encoding is structurally sound"
"$ODIN" check "$HERE/layout" -emit-layout:json -emit-layout-file:"$TMP/a.json" > /dev/null
"$ODIN" check "$HERE/layout" -emit-layout:json -emit-layout-file:"$TMP/b.json" > /dev/null
diff -u "$TMP/a.json" "$TMP/b.json"
# The CBOR writer states every map's pair count explicitly, and those counts are written by hand
# (`sw_map(&w, 7)`), so a version bump that adds a root key is one edit away from producing a
# document nothing can decode. JSON hides that mistake; this walks the CBOR and checks that each
# count matches what follows and that the document ends exactly where the root says it does.
"$ODIN" check "$HERE/atomic" -no-entry-point -emit-layout:cbor -emit-layout-file:"$TMP/a.cbor" > /dev/null
if command -v python3 > /dev/null 2>&1; then
	python3 "$HERE/cbor_lint.py" "$TMP/a.cbor"
else
	echo "  (python3 not found: the CBOR structural check was skipped)"
fi

echo "[3/29] hela-layout renders bytes and cache lines"
"$ODIN" build "$ROOT/cmd/hela-layout" -out:"$TMP/hela-layout" > /dev/null
"$TMP/hela-layout" "$TMP/a.json" Ring_Header > "$TMP/render.txt"
grep -q "cache lines 2" "$TMP/render.txt"
grep -q "@64" "$TMP/render.txt"

echo "[4/29] the layout tags reject what they promise to reject"
# dir:expected-message. Each one must fail to compile, and with the message that explains why.
for case in \
	"explicit_fail:requires every byte to be named" \
	"split_plain:is a Hela feature" \
	"split_conflict:keep only '#split'" \
	"align_below:is below the natural alignment" \
	"align_plain:is a Hela feature" \
	"align_explicit:'#align' inserts unnamed padding" \
	"align_split:would break the stride" \
	"aosoa_plain:is a Hela feature" \
	"aosoa_multiple:multiple of the block width" \
	"aosoa_width:must be a power of two" \
	"aosoa_elem:needs a struct element type" \
	"sharing_fail:False sharing" \
	"offset_plain:is a Hela feature" \
	"offset_misaligned:is not a multiple of the field type's alignment" \
	"offset_backwards:but the previous field already ends at byte" \
	"offset_conflict:both place this field" \
	"offset_packed:a packed struct is defined by having no gaps" \
	"atomic_plain:'#atomic' on a field is a Hela feature" \
	"atomic_bad_type:requires a lock-free 1/2/4/8-byte" \
	"atomic_no_share:needs a '#share(label)' naming the writer" \
	"atomic_packed:cannot be combined with '#packed'" \
	"alloc_fail:hides a possible allocation" \
	"bit_not_field:expects a bit_field type" \
	"bit_no_field:is not a field of type" \
	"bit_overflow:does not fit in the"
do
	dir=${case%%:*}
	want=${case#*:}
	if "$ODIN" check "$HERE/$dir" -no-entry-point > "$TMP/err.txt" 2>&1; then
		echo "FAIL: $dir compiled, but it must not"
		exit 1
	fi
	if ! grep -qF "$want" "$TMP/err.txt"; then
		echo "FAIL: $dir failed with the wrong message; wanted: $want"
		cat "$TMP/err.txt"
		exit 1
	fi
done

echo "[5/29] -emit-layout-for narrows the manifest"
"$ODIN" check "$HERE/layout" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/for.json" -emit-layout-for:"$HERE/abi" > /dev/null
if grep -q '"name":"Ring_Header"' "$TMP/for.json"; then
	echo "FAIL: -emit-layout-for:abi still exported tests/hela/layout"
	exit 1
fi
"$ODIN" check "$HERE/layout" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/for2.json" -emit-layout-for:"$HERE/layout/main.odin" > /dev/null
grep -q '"name":"Ring_Header"' "$TMP/for2.json"

echo "[6/29] -layout-cache-line moves cache-line boundaries"
"$ODIN" check "$HERE/abi" -no-entry-point -layout-cache-line:128 \
	-emit-layout:json -emit-layout-file:"$TMP/cl128.json" > /dev/null
grep -q '"cache_line":128' "$TMP/cl128.json"
# Ring_Header is 128 bytes: two 64 B lines, one 128 B line.
"$TMP/hela-layout" "$TMP/cl128.json" Ring_Header > "$TMP/render128.txt"
grep -q "cache lines 1" "$TMP/render128.txt"
# The intrinsic must agree with the manifest, so `tests/hela/layout`, which asserts two 64 B
# lines for Ring_Header, now has to fail.
if "$ODIN" check "$HERE/layout" -no-entry-point -layout-cache-line:128 > "$TMP/cl_err.txt" 2>&1; then
	echo "FAIL: layout_cache_lines_of ignored -layout-cache-line"
	exit 1
fi
grep -q "layout_cache_lines_of(Ring_Header) == 2" "$TMP/cl_err.txt"

echo "[7/29] ABI gate against tests/hela/abi/golden.hash"
"$ODIN" check "$HERE/abi" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/abi.json" > /dev/null
"$TMP/hela-layout" --hashes "$TMP/abi.json" > "$TMP/abi.hash"
if [ "${HELA_UPDATE_GOLDEN:-0}" = "1" ]; then
	cp "$TMP/abi.hash" "$HERE/abi/golden.hash"
	echo "golden file updated: $HERE/abi/golden.hash"
else
	diff -u "$HERE/abi/golden.hash" "$TMP/abi.hash"
fi

echo "[8/29] cross-target ABI gate (manifest v7 + --stable)"
# `tests/hela/abi` pins host-only numbers in #assert, so it cannot be cross-checked. `cross`
# contains only assertions that hold on every target; each one gets its own committed golden file.
CROSS_TARGETS="darwin_arm64 linux_amd64 windows_amd64 linux_i386 wasi_wasm32"
for t in $CROSS_TARGETS; do
	"$ODIN" check "$HERE/cross" -no-entry-point -target:$t \
		-emit-layout:json -emit-layout-file:"$TMP/cross_$t.json" > /dev/null
	grep -q "\"target\":\"$t\"" "$TMP/cross_$t.json"
	grep -q '"version":8' "$TMP/cross_$t.json"
	"$TMP/hela-layout" --hashes "$TMP/cross_$t.json" > "$TMP/cross_$t.hash"
	if [ "${HELA_UPDATE_GOLDEN:-0}" = "1" ]; then
		cp "$TMP/cross_$t.hash" "$HERE/cross/golden.$t.hash"
	else
		diff -u "$HERE/cross/golden.$t.hash" "$TMP/cross_$t.hash"
	fi
done
# The metadata must say which target was checked; layout_hash itself stays target-free.
grep -q '"pointer_size":8' "$TMP/cross_linux_amd64.json"
grep -q '"pointer_size":4' "$TMP/cross_linux_i386.json"
if [ "${HELA_UPDATE_GOLDEN:-0}" = "1" ]; then
	echo "  golden files updated: $HERE/cross/golden.*.hash"
fi

"$TMP/hela-layout" --stable \
	"$TMP/cross_darwin_arm64.json" "$TMP/cross_linux_amd64.json" \
	"$TMP/cross_windows_amd64.json" "$TMP/cross_linux_i386.json" \
	"$TMP/cross_wasi_wasm32.json" > "$TMP/cross_stable.txt"
cat "$TMP/cross_stable.txt"
# A wire format and a declared cache-line contract must be byte-identical everywhere...
grep -q 'STABLE  cross::Fixed_Wire' "$TMP/cross_stable.txt"
grep -q 'STABLE  cross::Aligned_Counters' "$TMP/cross_stable.txt"
# ...and the gate must still be able to *see* drift. `Unpinned_Wire` pins every #offset but lets
# the target pick the struct alignment; `Native_Record` contains pointer-sized fields.
grep -q 'DRIFT   cross::Unpinned_Wire' "$TMP/cross_stable.txt"
grep -q 'DRIFT   cross::Native_Record' "$TMP/cross_stable.txt"
grep -q '2 stable, 2 drifting, 0 missing' "$TMP/cross_stable.txt"
# A stale v5 manifest has no `target`; `--stable` must refuse it rather than silently comparing a
# host manifest against another manifest and calling the result "cross-target".
sed 's/"version":8/"version":5/' "$TMP/cross_darwin_arm64.json" > "$TMP/cross_v5.json"
if "$TMP/hela-layout" --stable "$TMP/cross_v5.json" "$TMP/cross_linux_amd64.json" > /dev/null 2>&1; then
\techo "FAIL: --stable accepted a manifest without target metadata"
\texit 1
fi

echo "[9/29] core:hela/ring layout + two-thread correctness"
"$ODIN" run "$HERE/ring" -o:speed -out:"$TMP/ring" > "$TMP/ring.txt"
grep -q "ring tests: ok" "$TMP/ring.txt"
sed -n '2,5p' "$TMP/ring.txt"

echo "[10/29] struct #split(N) matches hand-written padding"
"$ODIN" run "$HERE/split" -o:speed -out:"$TMP/split" > "$TMP/split.txt"
grep -q "split tests: ok" "$TMP/split.txt"

# The two spellings must hash the same. `layout_hash` is a fingerprint of the bytes, so padding
# fields (`_`) are left out of it; if this ever diverges, either the layouts differ or the hash has
# started describing the source instead of the memory.
"$ODIN" check "$HERE/split" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/split.json" > /dev/null
"$TMP/hela-layout" --hashes "$TMP/split.json" > "$TMP/split.hash"
manual_hash=$(awk -F'\t' '$1 == "split::Manual" {print $2}' "$TMP/split.hash")
split_hash=$(awk  -F'\t' '$1 == "split::Split"  {print $2}' "$TMP/split.hash")
if [ -z "$manual_hash" ] || [ "$manual_hash" != "$split_hash" ]; then
	echo "FAIL: layout_hash differs between the #explicit and #split spellings"
	cat "$TMP/split.hash"
	exit 1
fi

# Opt-in: the thread sanitizer is slow and needs the LLVM tsan runtime, so it is not part of the
# default run. `HELA_TSAN=1 ./tests/hela/run.sh` checks the ring for data races.
if [ "${HELA_TSAN:-0}" = "1" ]; then
	echo "[tsan] core:hela/ring under the thread sanitizer"
	"$ODIN" build "$HERE/ring" -sanitize:thread -o:speed -out:"$TMP/ring_tsan" > /dev/null
	"$TMP/ring_tsan" > "$TMP/tsan.txt" 2>&1
	grep -q "ring tests: ok" "$TMP/tsan.txt"
	if grep -qi "warning: thread sanitizer data race" "$TMP/tsan.txt"; then
		cat "$TMP/tsan.txt"
		echo "FAIL: the thread sanitizer reported a data race"
		exit 1
	fi
fi

echo "[11/29] field-level #align(N)"
"$ODIN" run "$HERE/field_align" -o:speed -out:"$TMP/field_align" > "$TMP/field_align.txt"
grep -q "field align tests: ok" "$TMP/field_align.txt"
"$ODIN" check "$HERE/field_align" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/align.json" > /dev/null
grep -q '"declared_align":64' "$TMP/align.json"
grep -q '"version":8' "$TMP/align.json"

echo "[12/29] #aosoa[W][N]T"
"$ODIN" run "$HERE/aosoa" -o:speed -out:"$TMP/aosoa" > "$TMP/aosoa.txt"
grep -q "aosoa tests: ok" "$TMP/aosoa.txt"
"$ODIN" check "$HERE/aosoa" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/aosoa.json" > /dev/null
# 128 blocks of 8: the manifest reports both numbers, so a tool never has to guess which one
# `count` means.
grep -q '"aosoa_width":8' "$TMP/aosoa.json"
grep -q '"elements":1024' "$TMP/aosoa.json"

echo "[13/29] #share + #+analysis sharing"
"$ODIN" run "$HERE/sharing" -o:speed -out:"$TMP/sharing" > "$TMP/sharing.txt"
grep -q "sharing tests: ok" "$TMP/sharing.txt"
# The escape hatch: the same false-sharing pair with the analysis off for the file.
"$ODIN" check "$HERE/sharing_off" -no-entry-point > /dev/null 2>&1 || {
	echo "FAIL: '#+analysis !sharing' did not turn the analysis off"
	exit 1
}
# ... and the analysis is measured against `-layout-cache-line`, not a hardcoded 64: 64-byte
# separation is two lines at 64 and one line at 128, so the same file must fail there.
if "$ODIN" check "$HERE/sharing" -no-entry-point -layout-cache-line:128 > "$TMP/share128.txt" 2>&1; then
	echo "FAIL: the sharing analysis ignored -layout-cache-line:128"
	exit 1
fi
grep -q "False sharing" "$TMP/share128.txt"
# Cross-type: two writers in two different nested types on one line is caught by the enclosing
# struct, which is the only place that can see both. A nested struct that starts off a cache line
# boundary is a warning (the nested type's analysis now describes the wrong bytes), not an error.
if ! "$ODIN" check "$HERE/sharing_fail" -no-entry-point > "$TMP/share_cross.txt" 2>&1; then
	grep -q "False sharing: 'b.head_hot'" "$TMP/share_cross.txt" || {
		echo "FAIL: cross-type false sharing failed with an unexpected message"
		cat "$TMP/share_cross.txt"
		exit 1
	}
else
	echo "FAIL: cross-type false sharing was not reported"
	exit 1
fi
"$ODIN" check "$HERE/sharing_misplaced" -vet -vet-tabs -strict-style -vet-style -disallow-do > "$TMP/share_misplaced.txt" 2>&1 || {
	echo "FAIL: misplaced nested struct should be a warning, not an error"
	cat "$TMP/share_misplaced.txt"
	exit 1
}
grep -q "not a multiple of the cache line" "$TMP/share_misplaced.txt" || {
	echo "FAIL: misplaced nested struct warning missing"
	exit 1
}

echo "[14/29] field-level #offset(N)"
"$ODIN" run "$HERE/field_offset" -o:speed -out:"$TMP/field_offset" > "$TMP/field_offset.txt"
grep -q "field offset tests: ok" "$TMP/field_offset.txt"
"$ODIN" check "$HERE/field_offset" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/offset.json" > /dev/null
# The manifest reports the pin, so a tool can tell "the compiler happened to put it at 16" from
# "the source required byte 16". Fields without `#offset` carry -1.
grep -q '"declared_offset":16' "$TMP/offset.json"
grep -q '"declared_offset":-1' "$TMP/offset.json"
"$TMP/hela-layout" "$TMP/offset.json" Registers > "$TMP/offset_render.txt"
grep -q "#offset(16)" "$TMP/offset_render.txt"

echo "[15/29] hela-layout --waste"
"$TMP/hela-layout" --waste "$TMP/abi.json" > "$TMP/waste.txt"
# `abi::Cursor` is 128 bytes holding 16 bytes of payload, and all of that padding is declared by
# `#split(64)` — the report must say so rather than presenting it as a mistake.
grep -q "abi::Cursor" "$TMP/waste.txt"
grep -q "#split(64)" "$TMP/waste.txt"
grep -q "recoverable by reordering" "$TMP/waste.txt"
# v8 gives the line size a provenance: `cache_line` alone cannot distinguish a decision from the
# compiler's fallback, and the report must not present a fallback as a measurement.
grep -q '"cache_line_explicit":false' "$TMP/abi.json"
grep -q "cache line 64 B (compiler default" "$TMP/waste.txt"
# ...and when the build *does* decide, the manifest says so.
"$ODIN" check "$HERE/atomic" -no-entry-point -layout-cache-line:16 \
	-emit-layout:json -emit-layout-file:"$TMP/cl16.json" > /dev/null
grep -q '"cache_line":16' "$TMP/cl16.json"
grep -q '"cache_line_explicit":true' "$TMP/cl16.json"
"$TMP/hela-layout" --waste "$TMP/cl16.json" | head -1 | grep -q "cache line 16 B (from -layout-cache-line)"
cat "$TMP/waste.txt"

echo "[16/29] #atomic: checked concurrency contract in the layout manifest"
"$ODIN" run "$HERE/atomic" -o:speed -out:"$TMP/atomic" > "$TMP/atomic.txt"
grep -q "atomic tests: ok" "$TMP/atomic.txt"
"$ODIN" check "$HERE/atomic" -no-entry-point -emit-layout:json -emit-layout-file:"$TMP/atomic.json" > /dev/null
grep -q '"version":8' "$TMP/atomic.json"
grep -q '"atomic":true' "$TMP/atomic.json"
grep -q '"share":"producer"' "$TMP/atomic.json"
grep -q '"atomic":false' "$TMP/atomic.json"
"$TMP/hela-layout" "$TMP/atomic.json" Cursors > "$TMP/atomic_render.txt"
grep -q "#atomic" "$TMP/atomic_render.txt"
grep -q "#share(producer)" "$TMP/atomic_render.txt"
echo "[17/29] hela-layout --contract, at the line size the manifest was built for and at another"
"$TMP/hela-layout" --contract "$TMP/atomic.json" > "$TMP/contract.txt"
grep -q "owner=producer" "$TMP/contract.txt"
grep -q "owner=consumer" "$TMP/contract.txt"
grep -q "head@0#atomic#share(producer)" "$TMP/contract.txt"
grep -q "0 line(s) with conflicting writers" "$TMP/contract.txt"
# The report must say *which* line it is describing, and that 64 was nobody's decision. A bare
# "cache line 64 B" reads like a measurement; it is the compiler's fallback until someone says
# otherwise, and on a 128-byte machine that difference is the whole question.
grep -q "cache line 64 B (compiler default" "$TMP/contract.txt"
cat "$TMP/contract.txt"

# One manifest, two line sizes, two answers -- no recompilation. The offsets are facts; the line
# size is a lens. `Cursors` is `#align(64)`-per-field, so at 128 B `head` (0..7) and `tail` (64..71)
# are on the SAME line and the producer/consumer contract is broken, even though the manifest was
# built for 64.
"$TMP/hela-layout" --contract --cache-line 128 "$TMP/atomic.json" > "$TMP/contract128.txt"
grep -q "cache line 128 B (--cache-line; the manifest was built for 64 B)" "$TMP/contract128.txt"
grep -q "owner=CONFLICT" "$TMP/contract128.txt"
grep -q "1 line(s) with conflicting writers" "$TMP/contract128.txt"
# ...and M25's invariant is re-evaluated at that line: 192 B is not a whole number of 128 B lines,
# so `[N]Cursors` would put element i's last field on element i+1's first line.
grep -q "not a whole number of 128 B lines" "$TMP/contract128.txt"
grep -q "main::Cursors(192 B)" "$TMP/contract128.txt"
cat "$TMP/contract128.txt"

# The compiler says the same thing when asked to *build* for that line: the tool's re-read is not a
# second opinion, it is the same rule. (Also the reason the default cannot simply be raised to 128:
# server ARM64 and x86-64 fetch 64, so a type that is one line there is half a line here.)
if "$ODIN" check "$HERE/atomic" -no-entry-point -layout-cache-line:128 > "$TMP/c128.txt" 2>&1; then
	echo "FAIL: -layout-cache-line:128 accepted a layout whose #share fields share a 128 B line"
	exit 1
fi
grep -q "both live in cache line 0" "$TMP/c128.txt"
grep -q "not a multiple of the cache line (128)" "$TMP/c128.txt"

echo "[18/29] #+analysis alloc"
"$ODIN" run "$HERE/alloc" -o:speed -out:"$TMP/alloc" > "$TMP/alloc.txt"
grep -q "alloc tests: ok" "$TMP/alloc.txt"
# Escape hatch 1: '#+analysis !alloc' on the file.
"$ODIN" check "$HERE/alloc_off" -no-entry-point > /dev/null
# Escape hatch 2: '-no-alloc-analysis' on the command line, over the same failing source.
"$ODIN" check "$HERE/alloc_fail" -no-entry-point -no-alloc-analysis > /dev/null
# ... and the analysis really is what rejects it (step 4 checks the message).

echo "[19/29] bit-segment masks come from the compiler, not from hex literals"
# Manifest v7 exports each bit_field segment's mask. `--bits` re-derives every mask from the
# segment bounds, so a stale or hand-edited manifest cannot quietly disagree with the compiler.
"$ODIN" check "$HERE/layout" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/bits.json" > /dev/null
grep -q '"version":8' "$TMP/bits.json"
grep -q '"bit_mask":"0x7"' "$TMP/bits.json"
grep -q '"bit_mask":"0xf8"' "$TMP/bits.json"
"$TMP/hela-layout" --bits "$TMP/bits.json" > "$TMP/bits.txt"
cat "$TMP/bits.txt"
grep -q 'bits 00..02  x' "$TMP/bits.txt"
grep -q 'mask=0x7  ok' "$TMP/bits.txt"
grep -q 'unused bits' "$TMP/bits.txt"
grep -q 'mask mismatches: 0' "$TMP/bits.txt"
# A v6 manifest has no `bit_mask` contract to read; --bits must refuse it.
sed 's/"version":8/"version":6/' "$TMP/bits.json" > "$TMP/bits_v6.json"
if "$TMP/hela-layout" --bits "$TMP/bits_v6.json" > /dev/null 2>&1; then
	echo "FAIL: --bits accepted a v6 manifest"
	exit 1
fi

echo "[20/29] reusable bit-pattern matching, checked exhaustively"
"$ODIN" run "$HERE/pattern" -o:speed -out:"$TMP/pattern" > "$TMP/pattern.txt"
cat "$TMP/pattern.txt"
grep -q "hela pattern tests: ok" "$TMP/pattern.txt"
grep -q "65536 words exhaustively checked" "$TMP/pattern.txt"
grep -q "no shadowed rules" "$TMP/pattern.txt"
# The two bit_field headers of that test must also be readable as bit maps.
"$ODIN" check "$HERE/pattern" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/pattern_layout.json" > /dev/null
"$TMP/hela-layout" --bits "$TMP/pattern_layout.json" > "$TMP/pattern_bits.txt"
grep -q 'backing=u16' "$TMP/pattern_bits.txt"
grep -q 'backing=u32' "$TMP/pattern_bits.txt"
grep -q 'mask mismatches: 0' "$TMP/pattern_bits.txt"
# The reusable structure's own bytes are pinned too: Rule / Node / Table are #explicit, and a
# 32-bit target must not lower the u64 alignment inside Rule (that is what #align(8) is for).
"$ODIN" check "$ROOT/core/hela/pattern" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/pattern_lib.json" > /dev/null
"$TMP/hela-layout" "$TMP/pattern_lib.json" Table_4 > "$TMP/pattern_table.txt"
grep -q 'size 752 B' "$TMP/pattern_table.txt"
grep -q 'padding 0 B' "$TMP/pattern_table.txt"
for t in $CROSS_TARGETS; do
	"$ODIN" check "$ROOT/core/hela/pattern" -no-entry-point -target:$t \
		-emit-layout:json -emit-layout-file:"$TMP/pat_$t.json" > /dev/null
done
"$TMP/hela-layout" --stable "$TMP/pat_darwin_arm64.json" "$TMP/pat_linux_amd64.json" \
	"$TMP/pat_windows_amd64.json" "$TMP/pat_linux_i386.json" "$TMP/pat_wasi_wasm32.json" \
	> "$TMP/pat_stable.txt"
grep -q '3 stable, 0 drifting, 0 missing' "$TMP/pat_stable.txt"

echo "[21/29] core:hela/flow: backpressure proved without threads"
"$ODIN" run "$HERE/flow" -o:speed -out:"$TMP/flow" > "$TMP/flow.txt"
cat "$TMP/flow.txt"
grep -q "hela flow backpressure tests: ok" "$TMP/flow.txt"
grep -q "24 plan cases, 160 topologies" "$TMP/flow.txt"
grep -q "80 Spin deadlocks detected, 80 Pump completions" "$TMP/flow.txt"
# The Gate and its reusable table are declared bytes, not a comment. Gate is #explicit #align(64),
# Table_8 is exactly eight lines, and every target must agree (32-bit must not shrink them).
"$ODIN" check "$ROOT/core/hela/flow" -no-entry-point -emit-layout:json \
	-emit-layout-file:"$TMP/flow_layout.json" > /dev/null
"$TMP/hela-layout" "$TMP/flow_layout.json" > "$TMP/flow_render.txt"
grep -q "size 64 B" "$TMP/flow_render.txt"
grep -q "size 512 B" "$TMP/flow_render.txt"
grep -q "padding 0 B" "$TMP/flow_render.txt"
"$TMP/hela-layout" --contract "$TMP/flow_layout.json" > "$TMP/flow_contract.txt"
grep -q "owner=worker" "$TMP/flow_contract.txt"
grep -q "0 line(s) with conflicting writers" "$TMP/flow_contract.txt"
for t in $CROSS_TARGETS; do
	"$ODIN" check "$ROOT/core/hela/flow" -no-entry-point -target:$t \
		-emit-layout:json -emit-layout-file:"$TMP/flow_$t.json" > /dev/null
done
"$TMP/hela-layout" --stable "$TMP/flow_darwin_arm64.json" "$TMP/flow_linux_amd64.json" \
	"$TMP/flow_windows_amd64.json" "$TMP/flow_linux_i386.json" "$TMP/flow_wasi_wasm32.json" \
	> "$TMP/flow_stable.txt"
grep -q '4 stable, 0 drifting, 0 missing' "$TMP/flow_stable.txt"

echo "[22/29] every core:hela library under strict vet"
for pkg in layout ring mem queue msg event supervise cache log bench exec io pattern flow abi; do
	"$ODIN" check "$ROOT/core/hela/$pkg" -no-entry-point \
		-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do > /dev/null
done

echo "[23/29] end-to-end runtime stack"
"$ODIN" run "$HERE/runtime" -o:speed -out:"$TMP/runtime" > "$TMP/runtime.txt"
grep -q "hela runtime tests: ok" "$TMP/runtime.txt"
grep -q "no loss/duplication" "$TMP/runtime.txt"
cat "$TMP/runtime.txt"

echo "[24/29] core:hela/io real kernel event source"
"$ODIN" run "$HERE/io" -o:speed -out:"$TMP/io" > "$TMP/io.txt"
grep -q "io event source tests: ok" "$TMP/io.txt"
grep -q "real kernel completions" "$TMP/io.txt"
cat "$TMP/io.txt"
# The I/O source declares its own cache-line owner; `--contract` must show it with no conflicts.
"$ODIN" check "$ROOT/core/hela/io" -no-entry-point \
	-emit-layout:json -emit-layout-file:"$TMP/io_layout.json" > /dev/null
"$TMP/hela-layout" --contract "$TMP/io_layout.json" > "$TMP/io_contract.txt"
grep -q "owner=owner" "$TMP/io_contract.txt"
grep -q "0 line(s) with conflicting writers" "$TMP/io_contract.txt"

echo "[25/29] core:hela/exec thread-per-core runtime"
"$ODIN" run "$HERE/exec" -o:speed -out:"$TMP/exec" > "$TMP/exec.txt"
grep -q "exec thread-per-core tests: ok" "$TMP/exec.txt"
grep -q "no loss/duplication" "$TMP/exec.txt"
grep -q "I/O-driven deliveries" "$TMP/exec.txt"
# M19 would deadlock at capacity 8 < burst 256. If the pump did not run, this
# batch could not have completed, so pin both facts in the output.
grep -q "capacity 8 < burst 256" "$TMP/exec.txt"
grep -q "pump rounds" "$TMP/exec.txt"
cat "$TMP/exec.txt"
# The runtime's cache-line ownership is part of the deliverable, not a comment: exporting the
# manifest must show one owner per annotated line and no conflicting writers.
"$ODIN" check "$ROOT/core/hela/exec" -no-entry-point \
	-emit-layout:json -emit-layout-file:"$TMP/exec_layout.json" > /dev/null
"$TMP/hela-layout" --contract "$TMP/exec_layout.json" > "$TMP/exec_contract.txt"
grep -q "owner=workers" "$TMP/exec_contract.txt"
grep -q "owner=controller" "$TMP/exec_contract.txt"
grep -q "0 line(s) with conflicting writers" "$TMP/exec_contract.txt"

echo "[26/29] array elements: a writer-bearing type must be a whole cache line"
# The type-level rule (`#+analysis sharing` warns when it does not hold) and the measurement that
# justifies it: 40-byte `[dynamic]` headers in one array share lines across threads, and the same
# work with 64-byte elements is measurably faster. The rate is printed, never asserted — the
# machine decides the ratio.
"$ODIN" run "$HERE/array_share" -o:speed -out:"$TMP/array_share" > "$TMP/array_share.txt"
grep -q "array share tests: ok" "$TMP/array_share.txt"
grep -q "one line each" "$TMP/array_share.txt"

echo "[27/29] layout_hash_of: the manifest's hash as a compile-time constant"
# `#assert(layout_hash_of(T) == 0x…)` is an ABI pin that needs no golden file, and `core:hela/abi`
# carries the same number into a running process. Here the *whole* manifest is compared with what
# the compiler folded into the binary: every type in the package, not a hand-picked subset.
"$ODIN" check "$HERE/hash" -emit-layout:json -emit-layout-file:"$TMP/hash.json" > /dev/null
"$TMP/hela-layout" --hashes "$TMP/hash.json" | sed 's/^[^:]*:://' | sort > "$TMP/hash_manifest.txt"
"$ODIN" build "$HERE/hash" -o:speed -out:"$TMP/hash_bin" > /dev/null
"$TMP/hash_bin" "$TMP" > "$TMP/hash.txt"
grep -q "hash tests: ok" "$TMP/hash.txt"
cat "$TMP/hash.txt"
# One `<Name> TAB <hash>` line per type; the prose in between is filtered out.
awk -F'\t' 'NF==2 && $2 ~ /^[0-9a-f]+$/' "$TMP/hash.txt" | sort > "$TMP/hash_intrinsic.txt"
diff -u "$TMP/hash_manifest.txt" "$TMP/hash_intrinsic.txt"
echo "  $(wc -l < "$TMP/hash_manifest.txt" | tr -d ' ') types: manifest and intrinsic agree"
# The pins in the source are the same numbers, so a layout change breaks the build, not a diff.
grep -q 'WIRE_HASH' "$HERE/hash/main.odin"
# ...and the same pins compile for every target, which is the operational meaning of "the hash
# does not contain the target": one constant, five machines, the same bytes. `Record` only gets
# there because of its `#align(8)` — without it `linux_i386` drops `u64`'s alignment to 4.
for t in darwin_arm64 linux_amd64 windows_amd64 linux_i386 wasi_wasm32; do
	"$ODIN" check "$HERE/hash" -no-entry-point -target:$t > /dev/null
done
echo "  the same ABI pins compile for 5 targets"

echo "[28/29] memory hierarchy: levels, bandwidth, SIMD scan width, read vs mmap"
# Hela's layout decisions (`#align(64)`, `#share`, cache-line-sized writers) are bets about this
# curve, so the curve is measured rather than assumed. Quick mode keeps it under a second: the
# sizes shrink and the 1 GiB device test is skipped (that one belongs to an explicit run).
"$ODIN" run "$HERE/membw" -o:speed -no-bounds-check -out:"$TMP/membw" -- quick > "$TMP/membw.txt"
cat "$TMP/membw.txt"
# A probe that measured nothing is worse than no probe: pin the shape of the result.
grep -q "ns/access" "$TMP/membw.txt"
grep -q "GB/s" "$TMP/membw.txt"
grep -q "scan_pair_simd" "$TMP/membw.txt"
# The probe asserts the *shape* of the curve (ordered levels, one pass beating two, threads buying
# bandwidth) and exits non-zero when the shape is wrong, so this line is the regression gate: a
# second sweep creeping back into the scan path fails here, not in a code review.
grep -q "memory curve assertions: all ok" "$TMP/membw.txt"
# The scan functions panic if the needle is found (`the probe must miss`), so reaching this line
# also proves the two-candidate single-pass scan agrees with `index_byte` about "no hit".
grep -q "skipped in quick mode" "$TMP/membw.txt"

echo "[29/29] thread sanitizer (opt-in: HELA_TSAN=1)"
if [ "${HELA_TSAN:-0}" = "1" ]; then
	"$ODIN" build "$HERE/runtime" -sanitize:thread -o:speed -out:"$TMP/runtime_tsan" > /dev/null
	"$TMP/runtime_tsan" > "$TMP/runtime_tsan.txt" 2>&1
	grep -q "hela runtime tests: ok" "$TMP/runtime_tsan.txt"
	if grep -qi "warning: thread sanitizer data race" "$TMP/runtime_tsan.txt"; then
		cat "$TMP/runtime_tsan.txt"
		echo "FAIL: the thread sanitizer reported a data race in the runtime stack"
		exit 1
	fi
	echo "  TSAN: MPMC 2P/2C clean"

	"$ODIN" build "$HERE/io" -sanitize:thread -o:speed -out:"$TMP/io_tsan" > /dev/null
	"$TMP/io_tsan" > "$TMP/io_tsan.txt" 2>&1
	grep -q "io event source tests: ok" "$TMP/io_tsan.txt"
	if grep -qi "warning: thread sanitizer data race" "$TMP/io_tsan.txt"; then
		cat "$TMP/io_tsan.txt"
		echo "FAIL: the thread sanitizer reported a data race in the I/O source"
		exit 1
	fi
	echo "  TSAN: io event source clean"

	"$ODIN" build "$HERE/exec" -sanitize:thread -o:speed -out:"$TMP/exec_tsan" > /dev/null
	"$TMP/exec_tsan" > "$TMP/exec_tsan.txt" 2>&1
	grep -q "exec thread-per-core tests: ok" "$TMP/exec_tsan.txt"
	if grep -qi "warning: thread sanitizer data race" "$TMP/exec_tsan.txt"; then
		cat "$TMP/exec_tsan.txt"
		echo "FAIL: the thread sanitizer reported a data race in the exec runtime"
		exit 1
	fi
	echo "  TSAN: exec 4-worker SPSC matrix clean"
else
	echo "  skipped (set HELA_TSAN=1 to run)"
fi

echo "hela layout tests: ok"
