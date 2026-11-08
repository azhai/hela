#+dialect hela

// Compares two manifests and reports added, removed and changed types. `layout_hash` is what
// decides "changed", so a field rename or a reordering is caught even when size and align happen
// to stay the same.
//
// This is what makes layout a regression test: record a manifest in CI, regenerate it, diff it.
package layout

import "core:fmt"
import "core:strings"

// diff_report appends a report to `out` and reports whether the two manifests are identical.
diff_report :: proc(a, b: ^Manifest, out: ^strings.Builder) -> (same: bool) {
	same = true
	i := 0
	j := 0

	for i < len(a.types) && j < len(b.types) {
		x := &a.types[i]
		y := &b.types[j]
		switch {
		case less(x, y):
			same = false
			fmt.sbprintf(out, "- %s::%s\n", x.pkg, x.name)
			i += 1
		case less(y, x):
			same = false
			fmt.sbprintf(out, "+ %s::%s\n", y.pkg, y.name)
			j += 1
		case:
			if x.size != y.size || x.align != y.align || x.layout_hash != y.layout_hash {
				same = false
				fmt.sbprintf(out, "~ %s::%s\tsize %d -> %d\talign %d -> %d\thash %s -> %s\n",
					x.pkg, x.name, x.size, y.size, x.align, y.align, x.layout_hash, y.layout_hash)
			}
			i += 1
			j += 1
		}
	}
	for ; i < len(a.types); i += 1 {
		same = false
		fmt.sbprintf(out, "- %s::%s\n", a.types[i].pkg, a.types[i].name)
	}
	for ; j < len(b.types); j += 1 {
		same = false
		fmt.sbprintf(out, "+ %s::%s\n", b.types[j].pkg, b.types[j].name)
	}
	return same
}

// less orders types the way `-emit-layout` does: by package, then by name.
less :: proc(x, y: ^Type_Layout) -> bool {
	if x.pkg != y.pkg {
		return x.pkg < y.pkg
	}
	return x.name < y.name
}
