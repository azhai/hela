#+dialect hela

// Cross-target layout stability.
//
// `layout_hash` deliberately does not contain the target: it is a fingerprint of the *bytes*.
// So comparing manifests produced by `odin check -target:<os>_<arch>` answers a question that a
// single manifest cannot: "are these bytes the same on every machine I ship to?" A wire format
// must be STABLE; a struct containing `int`, `uintptr` or a pointer is expected to DRIFT on a
// 32-bit target, and this report makes that visible instead of letting it hide in a comment.
//
// The report is deterministic: types are listed in the order the (already stably sorted)
// manifests present them, and no hash map is involved.
package layout

import "core:fmt"
import "core:strings"

MAX_STABLE_TYPES :: 512

Stable_Key :: struct {
	pkg:  string,
	name: string,
}

stable_report :: proc(b: ^strings.Builder, manifests: []Manifest) {
	if len(manifests) == 0 {
		fmt.sbprintf(b, "cross-target layout stability: no manifests\n")
		return
	}

	fmt.sbprintf(b, "cross-target layout stability (%d manifest(s))\n\n", len(manifests))
	lines_distinct := 0
	line0 := 0
	for &m in manifests {
		l := line_of(&m)
		if line0 == 0 {
			line0 = l.bytes
		} else if l.bytes != line0 {
			lines_distinct += 1
		}
		fmt.sbprintf(b, "  %s  pointer=%d B  cache_line=%d B (%s)  version=%d  types=%d\n",
			m.target, m.pointer_size, l.bytes, line_source_name(l.source), m.version, len(m.types))
	}
	if lines_distinct > 0 {
		// `layout_hash` is a fingerprint of the bytes, and the line size is not one of them, so a
		// mixed set still compares. What is *not* comparable is `cache_line`/`spans_cache_line`:
		// two manifests that disagree about the line disagree about those fields by construction.
		fmt.sbprintf(b, "  note: manifests disagree about the cache line; `layout_hash` is unaffected"+
			" (it covers bytes, not line occupancy), line-derived fields are not compared\n")
	}
	fmt.sbprintf(b, "\n")

	// Union of every `pkg::name`, in manifest order. Fixed capacity keeps this allocation-free;
	// an ABI pin package has tens of types, not hundreds.
	keys: [MAX_STABLE_TYPES]Stable_Key
	key_count := 0
	for &m in manifests {
		for &t in m.types {
			found := false
			for &k in keys[:key_count] {
				if k.pkg == t.pkg && k.name == t.name {
					found = true
					break
				}
			}
			if !found && key_count < MAX_STABLE_TYPES {
				keys[key_count] = Stable_Key{pkg = t.pkg, name = t.name}
				key_count += 1
			}
		}
	}

	stable_count  := 0
	drift_count   := 0
	missing_count := 0
	for &k in keys[:key_count] {
		present := 0
		same    := true
		hash0   := ""
		for &m in manifests {
			t, ok := find_in(&m, k.pkg, k.name)
			if !ok {
				continue
			}
			present += 1
			if hash0 == "" {
				hash0 = t.layout_hash
			} else if t.layout_hash != hash0 {
				same = false
			}
		}

		if present < len(manifests) {
			missing_count += 1
			fmt.sbprintf(b, "MISSING %s::%s  (%d/%d)\n", k.pkg, k.name, present, len(manifests))
		} else if same {
			stable_count += 1
			fmt.sbprintf(b, "STABLE  %s::%s  %s\n", k.pkg, k.name, hash0)
		} else {
			drift_count += 1
			fmt.sbprintf(b, "DRIFT   %s::%s  (%d/%d)\n", k.pkg, k.name, present, len(manifests))
			for &m in manifests {
				t, ok := find_in(&m, k.pkg, k.name)
				if !ok {
					fmt.sbprintf(b, "    %s  (absent)\n", m.target)
					continue
				}
				fmt.sbprintf(b, "    %s  %s  size=%d align=%d\n",
					m.target, t.layout_hash, t.size, t.align)
			}
		}
	}

	fmt.sbprintf(b, "\n%d type(s): %d stable, %d drifting, %d missing\n",
		key_count, stable_count, drift_count, missing_count)
}
