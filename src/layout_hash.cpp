// layout_hash.cpp — the byte-identity fingerprint of a type.
//
// `type_set_offsets_of` (types.cpp) decides *where* the bytes are. This file decides *how to name*
// the resulting shape: a FNV-1a 64 hash over (kind, size, align, packed, soa, array shape and
// every named field's name/offset/size/bit range). Two things read it:
//
//   * `-emit-layout` writes it as `layout_hash` in the manifest (layout_writer.cpp);
//   * `intrinsics.layout_hash_of(T)` returns it as a compile-time constant (check_builtin.cpp).
//
// They must never disagree, so the computation lives here and only here. A manifest that says
// "these bytes are shape X" and a `#assert(layout_hash_of(T) == 0x…)` that says the same thing are
// then either both true or both false — there is no third place for the answer to drift to.
//
// This file is included once, from checker.cpp right after bit_layout.cpp, so both check_builtin.cpp
// (which evaluates the intrinsic) and layout_writer.cpp (which writes the manifest, included later
// from main.cpp) see it.

// What every `padding` / `cache_line` / `spans_cache_line` computation is measured against.
gb_internal i64 layout_cache_line(void) {
	return get_layout_cache_line();
}

// One row of the byte map. A superset of what the hash needs, because the manifest also wants to
// show alignment/atomic/share/padding — the hash simply ignores the parts that are not the bytes.
struct LayoutField {
	String name;
	String type;
	i64    offset;
	i64    size;
	i64    align;          // the alignment the offset was computed with
	i64    declared_align; // the `N` of `#align(N)` on the field, 0 when it has none
	i64    declared_offset; // the `N` of `#offset(N)` on the field, -1 when it has none
	bool   atomic;          // `#atomic`: this field is accessed with atomic operations
	String share;           // `#share(label)`: who writes it, empty when unannotated
	i64    bit_offset; // -1 when the field is not part of a bit field
	i64    bit_size;   //  0 when the field is not part of a bit field
	String bit_mask;   // hex mask of a bit segment, empty for ordinary fields
	i64    padding_before;
	bool   spans_cache_line;
};

gb_internal String layout_kind_name(Type *bt) {
	if (bt == nullptr) {
		return str_lit("invalid");
	}
	switch (bt->kind) {
	case Type_Basic:      return str_lit("basic");
	case Type_Struct:     return str_lit("struct");
	case Type_Union:      return str_lit("union");
	case Type_Enum:       return str_lit("enum");
	case Type_BitSet:     return str_lit("bit_set");
	case Type_BitField:   return str_lit("bit_field");
	case Type_Array:      return str_lit("array");
	case Type_Matrix:     return str_lit("matrix");
	case Type_SimdVector: return str_lit("simd");
	default:              return str_lit("other");
	}
}

gb_internal String layout_soa_name(Type *bt) {
	if (bt == nullptr || bt->kind != Type_Struct) {
		return str_lit("none");
	}
	switch (bt->Struct.soa_kind) {
	case StructSoa_None:    return str_lit("none");
	case StructSoa_Fixed:   return str_lit("fixed");
	case StructSoa_Slice:   return str_lit("slice");
	case StructSoa_Dynamic: return str_lit("dynamic");
	}
	return str_lit("none");
}

gb_internal void layout_field_cache_line(LayoutField *lf) {
	i64 cache_line = layout_cache_line();
	lf->spans_cache_line = (lf->offset % cache_line) + lf->size > cache_line;
}

gb_internal void layout_fields_of_struct(Type *bt, Array<LayoutField> *fields, i64 *padding_, i64 *tail_padding_) {
	i64 padding  = 0;
	i64 cursor   = 0;
	i64 size     = type_size_of(bt);
	for_array(i, bt->Struct.fields) {
		Entity *f = bt->Struct.fields[i];
		LayoutField lf = {};
		lf.name       = f->token.string;
		lf.offset     = cast(i64)bt->Struct.offsets[i];
		lf.size       = type_size_of(f->type);
		lf.align      = gb_max(type_align_of(f->type), type_field_align_of(f));
		lf.declared_align = type_field_align_of(f);
		lf.declared_offset = type_field_offset_of(f);
		lf.atomic = f->Variable.is_atomic;
		lf.share  = f->Variable.share_label;
		lf.bit_offset = -1;
		lf.type       = make_string_c(type_to_string(f->type, permanent_allocator()));
		if (lf.offset > cursor) {
			lf.padding_before = lf.offset - cursor;
			padding += lf.padding_before;
		}
		if (lf.offset + lf.size > cursor) {
			cursor = lf.offset + lf.size;
		}
		layout_field_cache_line(&lf);
		array_add(fields, lf);
	}
	if (size > cursor) {
		padding += size - cursor;
		*tail_padding_ = size - cursor;
	} else {
		*tail_padding_ = 0;
	}
	*padding_ = padding;
}

gb_internal void layout_fields_of_union(Type *bt, Array<LayoutField> *fields, i64 *padding_) {
	i64 size = type_size_of(bt);
	for (Type *variant : bt->Union.variants) {
		LayoutField lf = {};
		lf.name       = str_lit("");
		lf.offset     = 0;
		lf.size       = type_size_of(variant);
		lf.align      = type_align_of(variant);
		lf.declared_align = 0;
		lf.declared_offset = -1;
		lf.bit_offset = -1;
		lf.type       = make_string_c(type_to_string(variant, permanent_allocator()));
		layout_field_cache_line(&lf);
		array_add(fields, lf);
	}
	*padding_ = size - (bt->Union.tag_size + bt->Union.variant_block_size);
	if (*padding_ < 0) {
		*padding_ = 0;
	}
	(void)size;
}

// A u64 mask does not fit in a JSON integer on every reader, and a mask is most useful to a
// person (or a model) in hex anyway. The string is permanent because LayoutField outlives the
// stack frame that filled it in.
gb_internal String layout_hex_u64(u64 value) {
	char *buf = cast(char *)gb_alloc(permanent_allocator(), 20);
	gb_snprintf(buf, 20, "0x%llx", cast(unsigned long long)value);
	// gb_snprintf's return value includes the terminator on this platform; the String must not.
	return make_string_c(buf);
}

gb_internal void layout_fields_of_bit_field(Type *bt, Array<LayoutField> *fields, i64 *padding_) {
	for_array(i, bt->BitField.fields) {
		Entity *f = bt->BitField.fields[i];
		LayoutField lf = {};
		lf.name       = f->token.string;
		lf.offset     = 0;
		lf.size       = type_size_of(bt->BitField.backing_type);
		lf.align      = type_align_of(bt->BitField.backing_type);
		lf.declared_align = 0;
		lf.declared_offset = -1;
		lf.bit_offset = bt->BitField.bit_offsets[i];
		lf.bit_size   = bt->BitField.bit_sizes[i];
		// Same helper the `layout_bit_*` intrinsics use. A routing rule derived from the intrinsic
		// and the mask in this manifest therefore cannot disagree about the wire format.
		u64 mask = bit_field_mask(lf.bit_offset, lf.bit_size);
		lf.bit_mask = mask == 0 ? str_lit("") : layout_hex_u64(mask);
		lf.type       = make_string_c(type_to_string(bt->BitField.backing_type, permanent_allocator()));
		layout_field_cache_line(&lf);
		array_add(fields, lf);
	}
	*padding_ = 0;
}

// Fill `fields` (and the padding totals) for whatever shape `bt` has. Shared by the manifest and
// the hash so that "the fields the tool reports" and "the fields the hash covers" are one list.
gb_internal void layout_fields_of_type(Type *bt, Array<LayoutField> *fields, i64 *padding_, i64 *tail_padding_) {
	*padding_ = 0;
	*tail_padding_ = 0;
	if (bt == nullptr) {
		return;
	}
	if (bt->kind == Type_Struct || bt->kind == Type_Tuple) {
		// Reading `Struct.offsets` before this is a use of an uninitialised pointer; reading it
		// after a *premature* call can poison a polymorphic specialisation's cached layout. The
		// caller is responsible for passing a concrete type (see `layout_hash_of_type`).
		type_set_offsets(bt);
	}
	switch (bt->kind) {
	case Type_Struct:
		if (bt->Struct.soa_kind == StructSoa_None) {
			layout_fields_of_struct(bt, fields, padding_, tail_padding_);
		}
		break;
	case Type_Union:
		layout_fields_of_union(bt, fields, padding_);
		break;
	case Type_BitField:
		layout_fields_of_bit_field(bt, fields, padding_);
		break;
	default:
		break;
	}
}

gb_internal u64 layout_hash_bytes(u64 h, void const *data, isize len) {
	u8 const *p = cast(u8 const *)data;
	for (isize i = 0; i < len; i++) {
		h ^= cast(u64)p[i];
		h *= 1099511628211ull;
	}
	return h;
}

gb_internal u64 layout_hash_string(u64 h, String s) {
	h = layout_hash_bytes(h, s.text, s.len);
	h = layout_hash_bytes(h, "\x1f", 1); // separator, so "ab"+"c" != "a"+"bc"
	return h;
}

gb_internal u64 layout_hash_i64(u64 h, i64 v) {
	return layout_hash_bytes(h, &v, gb_size_of(v));
}

#define LAYOUT_HASH_SEED 1469598103934665603ull

// The fingerprint of the bytes, given a field list that was already built for `bt`.
//
// Deliberately NOT hashed: the type's own name, its package, its file/line, `#explicit`, `#split`,
// `#share`, `#atomic`, alignment/offset *declarations*, padding totals. Those are either metadata
// about the source or already implied by an offset/size. Two structs that occupy the same bytes the
// same way hash the same — which is what a wire format wants: `Header` and `Message_Prefix` with
// `{u32 kind, u32 len}` are interchangeable, and the hash says so.
gb_internal u64 layout_hash_combine(Type *bt, Array<LayoutField> const &fields) {
	i64 size  = type_size_of(bt);
	i64 align = type_align_of(bt);

	u64 hash = LAYOUT_HASH_SEED;
	hash = layout_hash_string(hash, layout_kind_name(bt));
	hash = layout_hash_i64(hash, size);
	hash = layout_hash_i64(hash, align);
	hash = layout_hash_i64(hash, bt->kind == Type_Struct && bt->Struct.is_packed);
	hash = layout_hash_string(hash, layout_soa_name(bt));
	if (bt->kind == Type_Array) {
		// For an array, "how many bytes" is not the whole story: `[8]u64` and `[2][4]u64` are
		// both 64 bytes but index differently, and an `#aosoa` block layout differs again. The
		// element type and the shape are part of the layout, so they are part of the hash.
		// The element type already carries `#aosoa`'s block width (`#soa[W]T`), so the hash
		// stays a fingerprint of the bytes: `#aosoa[8][32]Vec3` and `[4]#soa[8]Vec3` agree.
		hash = layout_hash_string(hash, make_string_c(type_to_string(bt->Array.elem, permanent_allocator())));
		hash = layout_hash_i64(hash, bt->Array.count);
	}
	for (LayoutField const &lf : fields) {
		// A `_` field is padding that happens to have a name: it occupies bytes, it is not part
		// of the interface. Skipping it makes `layout_hash` a fingerprint of the *bytes*, so the
		// same struct written as `#explicit` + `_: [56]u8` and as `#split(64)` hashes the same.
		// Nothing is lost: the bytes any padding covers still show up as the offset or size of
		// the fields around it, and as `size` itself.
		if (lf.name.len == 1 && lf.name[0] == '_') {
			continue;
		}
		hash = layout_hash_string(hash, lf.name);
		hash = layout_hash_i64(hash, lf.offset);
		hash = layout_hash_i64(hash, lf.size);
		hash = layout_hash_i64(hash, lf.bit_offset);
		hash = layout_hash_i64(hash, lf.bit_size);
	}
	return hash;
}

// The whole thing, including building the field list. `layout_hash_of` intrinsic and the manifest
// both end up here, so `#assert(layout_hash_of(T) == 0x…)` and `"layout_hash": "…"` in a manifest
// cannot disagree.
//
// The caller must pass a concrete type: computing offsets for a half-instantiated polymorphic type
// caches a wrong layout for the eventual specialisation (see 20-m24-cross-type-sharing.md).
gb_internal u64 layout_hash_of_type(Type *bt) {
	if (bt == nullptr) {
		return 0;
	}
	bt = base_type(bt);
	auto fields = array_make<LayoutField>(heap_allocator());
	defer (array_free(&fields));
	i64 padding = 0;
	i64 tail_padding = 0;
	layout_fields_of_type(bt, &fields, &padding, &tail_padding);
	return layout_hash_combine(bt, fields);
}
