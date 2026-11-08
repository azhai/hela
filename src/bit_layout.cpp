// bit_layout.cpp — the bit-level half of Hela's layout source of truth.
//
// `type_set_offsets_of` decides byte offsets; for a `bit_field` the compiler additionally decides
// which *bits* each field owns (`Type_BitField.bit_offsets` / `bit_sizes`). Everything that needs
// a bit mask — the `layout_bit_*` compile-time intrinsics and `-emit-layout` — must read those two
// arrays, not recompute them from source text. A mask written by hand in a routing table can
// silently disagree with the wire format; a mask derived here cannot.
//
// This file is included once, from checker.cpp right after types.cpp, so both check_builtin.cpp
// (which evaluates the intrinsics) and layout_writer.cpp (which writes the manifest) see it.

// Look a field up in a `bit_field` type. Returns false for a non-bit-field type, an unknown name,
// or an entity that is not a field. The caller reports the user-facing error.
gb_internal bool bit_field_lookup(Type *t, InternedString name, i64 *bit_offset_, i64 *bit_size_) {
	if (t == nullptr || t->kind != Type_BitField) {
		return false;
	}
	for_array(i, t->BitField.fields) {
		Entity *f = t->BitField.fields[i];
		if (f->kind != Entity_Variable || (f->flags & EntityFlag_Field) == 0) {
			continue;
		}
		if (entity_interned_name(f) == name) {
			*bit_offset_ = t->BitField.bit_offsets[i];
			*bit_size_   = t->BitField.bit_sizes[i];
			return true;
		}
	}
	return false;
}

// The mask of a bit segment, already shifted into its place in the backing word. `bit_size == 64`
// would overflow the shift, so it is handled separately. A segment that does not fit in a u64 is
// not representable by the pattern machinery and returns 0; the caller turns that into an error.
gb_internal u64 bit_field_mask(i64 bit_offset, i64 bit_size) {
	if (bit_size <= 0 || bit_offset < 0 || bit_offset + bit_size > 64) {
		return 0;
	}
	u64 m = bit_size >= 64 ? ~cast(u64)0 : ((cast(u64)1 << bit_size) - 1);
	return m << bit_offset;
}
