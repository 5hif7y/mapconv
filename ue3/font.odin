package ue3

import "core:fmt"
import "../diag"

// UFont::Serialize (Engine/Src/UnFont.cpp:19). From VER_FIXED_FONTS_SERIALIZATION
// (511) the characters, textures and kerning tables are ordinary tagged
// properties, so the native body left after the tag stream is just CharRemap, a
// TArray<INT>: a count followed by that many 32 bit values. Measured on the
// corpus: four bytes for fonts without a remap table and 2.052 for the ones that
// carry 512 entries.
Font_Body :: struct {
	remap: int,
}

read_font :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Font_Body, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	defer delete(head_d.items)
	if engine_version(&pkg.summary) < 511 {
		diag.err(&d, "ue3.font-version", "legacy font serialization is not supported")
		return
	}
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	count := read_i32(&r)
	if r.failed || count < 0 || count > 65_536 {
		diag.err(&d, "ue3.bad-font", fmt.aprintf("implausible remap count %d", count))
		return
	}
	if i64(count) * 4 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-font", "remap table overruns the export")
		return
	}
	// Entries are packed character codes: two 16 bit halves per 32 bit word, so
	// the value itself is not range checked; only INDEX_NONE is excluded.
	for _ in 0 ..< int(count) {
		value := read_i32(&r)
		if r.failed || value < -1 {
			diag.err(&d, "ue3.bad-font", fmt.aprintf("implausible remap entry %d", value))
			return
		}
	}
	result.remap = int(count)
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.font-layout", fmt.aprintf("UFont consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
