// `-emit-layout`: a deterministic, machine-readable description of the memory layout of every
// exported type.
//
// The compiler is the single source of truth for layout (`type_set_offsets_of` in types.cpp), so
// this pass only reads what the checker already computed. It exists so that tools — and language
// models — can reason about bytes (padding, alignment, cache-line occupancy, false sharing)
// instead of guessing them from source text.
//
// {
//     "version":      7,
//     "generator":    "hela",
//     "target":       "darwin_arm64",   // ODIN_OS + "_" + ODIN_ARCH of this check
//     "pointer_size": 8,
//     "cache_line":   64,               // what `cache_line` / `spans_cache_line` were measured against
//     "cache_line_explicit": false,     // true when `-layout-cache-line` chose that number
//     "types": [
//         {"name", "pkg", "file", "line", "kind",
//          "size", "align", "packed", "soa", "cache_lines",
//          "padding", "tail_padding", "explicit", "split", "layout_hash",
//          "fields"?:   [{"name", "type", "offset", "size", "align", "declared_align",
//                         "declared_offset", "atomic", "share", "cache_line",
//                         "spans_cache_line", "padding_before", "bit_offset", "bit_size",
//                         "bit_mask"}, ...],
//          "variants"?: [ same shape as fields ],   // unions
//          "elem"?, "count"?, "stride"?,            // arrays
//          "aosoa_width"?, "elements"?,             // `#aosoa[W][N]T`: W and the logical N
//          "rows"?, "columns"?, "row_major"?,       // matrices
//          "underlying"?,                           // enums, bit_sets
//          "backing"?}                              // bit_fields
//     ]
// }
//
// `layout_hash` is a FNV-1a 64 hash of the canonical layout (kind, size, align, packed, soa and
// every named field's name/offset/size/bit range). Padding fields (`_`) are excluded, so the hash
// is a fingerprint of the bytes rather than of the source spelling. It does not include file paths,
// so it is stable across machines and can be used to detect ABI drift in CI.
//
// It deliberately does NOT include `target`: the hash describes bytes, not the machine that was
// asked to lay them out. So the same hash under two targets means "these bytes are identical",
// which is exactly the property a wire format needs; a different hash means the target changed an
// alignment or a size. `target` and `pointer_size` are metadata for the reader, so that a
// manifest from a cross-check cannot be mistaken for one from the host.
//
// `padding` is the total number of bytes not covered by a named field (leading, interior and
// trailing). `tail_padding` is the part after the last field.
//
// `file` is written relative to the working directory whenever the file lives under it, so that
// two clones of the same repository produce byte identical manifests. Nothing in this file may
// depend on wall clock time, hash map iteration order or absolute paths.

enum : i64 {
	// 2: adds `explicit` and `split` to every type entry. Both are metadata about how the layout was
	// declared; consumers that only read bytes can ignore them.
	// 3: adds `declared_align` to every field entry (the `N` of a field-level `#align(N)`, 0 when
	// the field only has its type's natural alignment).
	// 4: adds `declared_offset` to every field entry (the `N` of a field-level `#offset(N)`, -1
	// when the field is placed by the ordinary alignment rules).
	// 5: adds the concurrency contract to every field: `atomic` (from `#atomic`) and `share`
	// (the writer named by `#share(label)`, empty when none). Neither changes a byte, so
	// `layout_hash` is unchanged; ABI gates stay valid across this version bump.
	// 6: adds `target` (`ODIN_OS`_`ODIN_ARCH`) and `pointer_size` to the manifest root. Both are
	// metadata about which target was checked, not about the bytes: `layout_hash` is unchanged,
	// so existing golden files stay valid and the same hash can be compared across targets.
	// 7: adds `bit_mask` to every field of a `bit_field` type (hex string, already shifted into
	// place). It is derived from the same `bit_offset`/`bit_size` arrays as the
	// `layout_bit_*` intrinsics, so it cannot change the bytes: `layout_hash` is unchanged.
	// 8: adds `cache_line_explicit` to the root: true when `-layout-cache-line` chose the number,
	// false when it is `LAYOUT_DEFAULT_CACHE_LINE`. `cache_line` alone cannot tell a reader whether
	// 64 was a decision or a default — and on a machine that fetches 128 bytes the difference is
	// the whole point of the field. Metadata, so `layout_hash` is unchanged. The number is a
	// *reading* parameter too: `hela-layout --cache-line N` re-derives line occupancy from the
	// offsets, which are facts, so one manifest can be audited against any line size.
	LAYOUT_VERSION = 8,
};

gb_internal void sw_bool(SemanticsWriter *w, bool value) {
	switch (w->format) {
	case SemanticsFormat_Json:
		sw_json_value(w);
		if (value) {
			sw_bytes(w, "true", 4);
		} else {
			sw_bytes(w, "false", 5);
		}
		break;
	case SemanticsFormat_Cbor:
		sw_cbor_head(w, CborMajor_Simple, value ? 21 : 20);
		break;
	default:
		GB_PANIC("Unhandled SemanticsFormat %d", cast(int)w->format);
		break;
	}
}

gb_internal bool layout_type_has_layout(Type *bt) {
	if (bt == nullptr || bt == t_invalid) {
		return false;
	}
	switch (bt->kind) {
	case Type_Basic:
	case Type_Struct:
	case Type_Union:
	case Type_Enum:
	case Type_BitSet:
	case Type_BitField:
	case Type_Array:
	case Type_Matrix:
	case Type_SimdVector:
		return true;
	default:
		return false;
	}
}

gb_internal String layout_trim_trailing_separators(String s) {
	while (s.len > 0 && (s[s.len-1] == '/' || s[s.len-1] == '\\')) {
		s.len -= 1;
	}
	return s;
}

// A `-emit-layout-for` entry names either a single file or a directory. Directories match
// everything underneath them, which is what people actually want to type for a big package.
gb_internal bool layout_path_matches(String spec_in, String file) {
	String spec = layout_trim_trailing_separators(spec_in);
	if (spec.len == 0) {
		return false;
	}
	if (overlay_path_eq(spec, file)) {
		return true;
	}
	if (spec.len < file.len && string_starts_with(file, spec)) {
		char c = file[spec.len];
		if (c == '/' || c == '\\') {
			return true;
		}
	}
	return false;
}

// The manifest records where a type was declared, but an absolute path would make two clones of
// the same repository produce different bytes. So: relative to the working directory when the
// file lives under it, absolute otherwise.
gb_internal String layout_relative_path(String full) {
	if (full.len == 0) {
		return full;
	}
	static String cached_cwd = {};
	if (cached_cwd.text == nullptr) {
		cached_cwd = get_working_directory(permanent_allocator());
	}
	if (cached_cwd.len == 0 || cached_cwd.len >= full.len) {
		return full;
	}
	if (!string_starts_with(full, cached_cwd)) {
		return full;
	}
	char after = full[cached_cwd.len];
	if (after != '/' && after != '\\') {
		return full; // e.g. "/a/bc" is not under "/a/b"
	}
	String rest = substring(full, cached_cwd.len, full.len);
	rest = substring(rest, 1, rest.len); // drop the separator that follows the workdir
	if (rest.len == 0) {
		return full;
	}
	return rest;
}

gb_internal GB_COMPARE_PROC(layout_type_cmp) {
	Entity *x = *cast(Entity *const *)a;
	Entity *y = *cast(Entity *const *)b;
	String xpkg = x->pkg != nullptr ? x->pkg->name : String{};
	String ypkg = y->pkg != nullptr ? y->pkg->name : String{};
	int c = string_compare(xpkg, ypkg);
	if (c != 0) {
		return c;
	}
	return string_compare(x->token.string, y->token.string);
}

gb_internal void sw_layout_fields(SemanticsWriter *w, Array<LayoutField> const &fields) {
	sw_array(w, fields.count);
	for (LayoutField const &lf : fields) {
		sw_map(w, 15);
		sw_key(w, "name");              sw_string(w, lf.name);
		sw_key(w, "type");              sw_string(w, lf.type);
		sw_key(w, "offset");            sw_int(w, lf.offset);
		sw_key(w, "size");              sw_int(w, lf.size);
		sw_key(w, "align");             sw_int(w, lf.align);
		sw_key(w, "declared_align");    sw_int(w, lf.declared_align);
		sw_key(w, "declared_offset");   sw_int(w, lf.declared_offset);
		sw_key(w, "atomic");            sw_bool(w, lf.atomic);
		sw_key(w, "share");             sw_string(w, lf.share);
		sw_key(w, "cache_line");        sw_int(w, lf.offset / layout_cache_line());
		sw_key(w, "spans_cache_line");  sw_bool(w, lf.spans_cache_line);
		sw_key(w, "padding_before");    sw_int(w, lf.padding_before);
		sw_key(w, "bit_offset");        sw_int(w, lf.bit_offset);
		sw_key(w, "bit_size");          sw_int(w, lf.bit_size);
		sw_key(w, "bit_mask");          sw_string(w, lf.bit_mask);
		sw_map_end(w);
	}
	sw_array_end(w);
}

gb_internal void emit_layout(Checker *c) {
	CheckerInfo *info = &c->info;

	auto exported = array_make<bool>(heap_allocator(), global_files.count);
	defer (array_free(&exported));
	for_array(i, exported) {
		exported[i] = false;
	}

	for (AstPackage *pkg : c->parser->packages) {
		for (AstFile *f : pkg->files) {
			if (f->id <= 0 || f->id >= exported.count) {
				continue;
			}
			if (build_context.emit_layout_for.count == 0) {
				// Default to the packages being compiled, the same rule `-export-semantics` uses.
				exported[f->id] = pkg->kind == Package_Init || pkg->is_extra;
				continue;
			}
			for (String const &path : build_context.emit_layout_for) {
				if (layout_path_matches(path, f->fullpath)) {
					exported[f->id] = true;
				}
			}
		}
	}

	auto types = array_make<Entity *>(heap_allocator());
	defer (array_free(&types));

	for (Entity *e : info->entities) {
		if (e == nullptr || e->kind != Entity_TypeName) {
			continue;
		}
		if (e->type == nullptr || e->type == t_invalid || is_type_polymorphic(e->type)) {
			continue;
		}
		i32 file_id = e->token.pos.file_id;
		if (file_id <= 0 || file_id >= exported.count || !exported[file_id]) {
			continue;
		}
		Type *bt = base_type(e->type);
		if (!layout_type_has_layout(bt)) {
			continue;
		}
		array_add(&types, e);
	}
	array_sort(types, layout_type_cmp);

	SemanticsWriter w = {};
	w.format = build_context.emit_layout_format;
	w.buf    = array_make<u8>(heap_allocator(), 0, 1<<16);
	w.items  = array_make<i32>(heap_allocator());
	defer (array_free(&w.buf));
	defer (array_free(&w.items));

	// `target` and `pointer_size` say which target this *check* was run for. They are not part of
	// `layout_hash`: a cross-checked manifest has to be comparable to a host one byte-for-byte.
	// Keep the map length in sync here — JSON tolerates a wrong count, CBOR does not.
	String layout_target = concatenate3_strings(permanent_allocator(),
	                                           build_context.ODIN_OS, str_lit("_"),
	                                           build_context.ODIN_ARCH);
	sw_map(&w, 7);
	sw_key(&w, "version");      sw_int(&w, LAYOUT_VERSION);
	sw_key(&w, "generator");    sw_string(&w, str_lit("hela"));
	sw_key(&w, "target");       sw_string(&w, layout_target);
	sw_key(&w, "pointer_size"); sw_int(&w, build_context.ptr_size);
	sw_key(&w, "cache_line");   sw_int(&w, layout_cache_line());
	// Whether that number was chosen or defaulted. `cache_line` is the only field in the manifest
	// that describes the *reader's* assumption rather than the program's bytes, so it has to say
	// where it came from: `-layout-cache-line` is a decision, the default is a placeholder that a
	// 128-byte-line machine silently disagrees with.
	sw_key(&w, "cache_line_explicit"); sw_bool(&w, build_context.layout_cache_line > 0);
	sw_key(&w, "types");
	sw_array(&w, types.count);

	auto fields = array_make<LayoutField>(heap_allocator());
	defer (array_free(&fields));

	for (Entity *e : types) {
		Type *bt = base_type(e->type);
		if (bt->kind == Type_Struct || bt->kind == Type_Tuple) {
			type_set_offsets(bt);
		}

		i64 size  = type_size_of(e->type);
		i64 align = type_align_of(e->type);
		i64 padding = 0;
		i64 tail_padding = 0;

		// Field enumeration and the hash both come from layout_hash.cpp: the manifest reports a
		// shape and `intrinsics.layout_hash_of` asserts the same shape, and neither recomputes it.
		array_clear(&fields);
		layout_fields_of_type(bt, &fields, &padding, &tail_padding);

		i64 cache_lines = (size + layout_cache_line()-1) / layout_cache_line();
		i64 aosoa_width = bt->kind == Type_Array ? cast(i64)bt->Array.aosoa_width : 0;

		u64 hash = layout_hash_combine(bt, fields);

		char hash_text[17] = {};
		{
			u64 h = hash;
			for (isize i = 15; i >= 0; i--) {
				hash_text[i] = "0123456789abcdef"[h & 0xf];
				h >>= 4;
			}
		}

		isize kind_extra = 0;
		switch (bt->kind) {
		case Type_Array:      kind_extra = aosoa_width > 0 ? 5 : 3; break;
		case Type_Matrix:     kind_extra = 4; break;
		case Type_Enum:
		case Type_BitSet:     kind_extra = 1; break;
		case Type_BitField:   kind_extra = 1; break;
		default:              kind_extra = 0; break;
		}
		// name, pkg, file, line, kind, size, align, packed, soa, cache_lines,
		// padding, tail_padding, explicit, split, layout_hash = 15
		isize entry_keys = 15 + kind_extra + (fields.count > 0);

		sw_map(&w, entry_keys);
		sw_key(&w, "name");        sw_string(&w, e->token.string);

		sw_key(&w, "pkg");
		if (e->pkg != nullptr) {
			sw_string(&w, e->pkg->name);
		} else {
			sw_string(&w, str_lit(""));
		}

		sw_key(&w, "file");
		if (e->token.pos.file_id > 0) {
			sw_string(&w, layout_relative_path(get_file_path_string(e->token.pos.file_id)));
		} else {
			sw_string(&w, str_lit(""));
		}

		sw_key(&w, "line");          sw_int(&w, cast(i64)e->token.pos.line);
		sw_key(&w, "kind");          sw_string(&w, layout_kind_name(bt));
		sw_key(&w, "size");          sw_int(&w, size);
		sw_key(&w, "align");         sw_int(&w, align);
		sw_key(&w, "packed");        sw_bool(&w, bt->kind == Type_Struct && bt->Struct.is_packed);
		sw_key(&w, "soa");           sw_string(&w, layout_soa_name(bt));
		sw_key(&w, "cache_lines");   sw_int(&w, cache_lines);
		sw_key(&w, "padding");       sw_int(&w, padding);
		sw_key(&w, "tail_padding");  sw_int(&w, tail_padding);
		// How the layout was declared, not how it came out. `explicit` means every byte is named
		// (`#explicit`), `split` is the stride of `#split(N)`, 0 when neither is used. Both are
		// metadata: the bytes are already described by `size`/`align`/`fields`, so neither takes
		// part in `layout_hash`.
		sw_key(&w, "explicit");      sw_bool(&w, bt->kind == Type_Struct && bt->Struct.is_explicit_layout);
		sw_key(&w, "split");         sw_int(&w, bt->kind == Type_Struct ? bt->Struct.split_align : 0);
		sw_key(&w, "layout_hash");   sw_string(&w, make_string(cast(u8 *)hash_text, 16));

		switch (bt->kind) {
		case Type_Array:
			sw_key(&w, "elem");
			sw_string(&w, make_string_c(type_to_string(bt->Array.elem, permanent_allocator())));
			// `count` is the length of the array as the type system sees it. For `#aosoa` that is
			// the number of *blocks*, and `elements` is the logical element count the program
			// indexes with, so `count * aosoa_width == elements` and `count * stride == size`.
			sw_key(&w, "count");  sw_int(&w, bt->Array.count);
			sw_key(&w, "stride"); sw_int(&w, type_size_of(bt->Array.elem));
			if (aosoa_width > 0) {
				sw_key(&w, "aosoa_width"); sw_int(&w, aosoa_width);
				sw_key(&w, "elements");    sw_int(&w, cast(i64)bt->Array.count * aosoa_width);
			}
			break;
		case Type_Matrix:
			sw_key(&w, "rows");      sw_int(&w, bt->Matrix.row_count);
			sw_key(&w, "columns");   sw_int(&w, bt->Matrix.column_count);
			sw_key(&w, "stride");    sw_int(&w, bt->Matrix.stride_in_bytes);
			sw_key(&w, "row_major"); sw_bool(&w, bt->Matrix.is_row_major);
			break;
		case Type_Enum:
			sw_key(&w, "underlying");
			sw_string(&w, make_string_c(type_to_string(bt->Enum.base_type, permanent_allocator())));
			break;
		case Type_BitSet:
			sw_key(&w, "underlying");
			sw_string(&w, make_string_c(type_to_string(bt->BitSet.underlying, permanent_allocator())));
			break;
		case Type_BitField:
			sw_key(&w, "backing");
			sw_string(&w, make_string_c(type_to_string(bt->BitField.backing_type, permanent_allocator())));
			break;
		default:
			break;
		}

		if (fields.count > 0) {
			sw_key(&w, bt->kind == Type_Union ? "variants" : "fields");
			sw_layout_fields(&w, fields);
		}
		sw_map_end(&w);
	}
	sw_array_end(&w);
	sw_map_end(&w);

	String path = build_context.emit_layout_file;
	if (path.len == 0) {
		path = w.format == SemanticsFormat_Cbor ? str_lit("layout.cbor") : str_lit("layout.json");
	}
	char const *cpath = alloc_cstring(temporary_allocator(), path);
	gbFile f = {};
	if (gb_file_create(&f, cpath) != gbFileError_None) {
		error(TokenPos{}, "Unable to create the layout file '%.*s'", LIT(path));
		return;
	}
	defer (gb_file_close(&f));
	gb_file_write(&f, w.buf.data, w.buf.count);
}
