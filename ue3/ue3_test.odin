package ue3

import "core:strings"
import "core:testing"
import "../diag"

// The test package is assembled by hand so the byte layout is explicit and the
// parser is checked against the documented offsets rather than against itself.

Builder :: struct {
	buf: [dynamic]u8,
}

put_u32 :: proc(b: ^Builder, v: u32) {
	append(&b.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

put_i32 :: proc(b: ^Builder, v: i32) {
	put_u32(b, u32(v))
}

put_u64 :: proc(b: ^Builder, v: u64) {
	put_u32(b, u32(v))
	put_u32(b, u32(v >> 32))
}

put_bytes :: proc(b: ^Builder, data: []u8) {
	append(&b.buf, ..data)
}

put_fstring :: proc(b: ^Builder, s: string) {
	if len(s) == 0 {
		put_i32(b, 0)
		return
	}
	put_i32(b, i32(len(s) + 1))
	put_bytes(b, transmute([]u8)s)
	append(&b.buf, 0)
}

put_name_entry :: proc(b: ^Builder, text: string, flags: u64) {
	put_fstring(b, text)
	put_u64(b, flags)
}

put_name_ref :: proc(b: ^Builder, index: i32, number: i32) {
	put_i32(b, index)
	put_i32(b, number)
}

put_guid :: proc(b: ^Builder) {
	for i in 0..<16 {
		append(&b.buf, u8(0x10 + i))
	}
}

// build_package lays out one complete 576/5 package:
//
//	names:   None, Class, Package, Engine, Level, Brush
//	imports: 0 Engine (package), 1 Level (class)
//	exports: 0 Level (class import 1, top level), 1 Brush (class import 1, outer export 0)
//
// It also carries one additional cook package, "EpicMap", as a real map does.
build_package :: proc() -> [dynamic]u8 {
	// Fixed summary fields before the additional-package array: tag, version,
	// header size, folder "", flags, 7 counts/offsets, guid, generation count and
	// one generation, engine, cooked, compression flags, chunk count, package
	// source. The additional-package count and array follow and are accounted for
	// by `ab.buf` below.
	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4

	names: [dynamic]u8
	nb := Builder{buf = names}
	put_name_entry(&nb, "None", 0)
	put_name_entry(&nb, "Class", 0)
	put_name_entry(&nb, "Package", 0)
	put_name_entry(&nb, "Engine", 0)
	put_name_entry(&nb, "Level", 0)
	put_name_entry(&nb, "Brush", 0)

	imports: [dynamic]u8
	ib := Builder{buf = imports}
	// 0: Engine package (an object whose class is Package).
	put_name_ref(&ib, 2, 0) // class_package = Package
	put_name_ref(&ib, 1, 0) // class_name = Class
	put_i32(&ib, 0) // outer = null
	put_name_ref(&ib, 3, 0) // object_name = Engine
	// 1: Level class (an object whose class is Class, outer = Engine).
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1) // outer = import 0 (Engine)
	put_name_ref(&ib, 4, 0) // object_name = Level

	exports: [dynamic]u8
	eb := Builder{buf = exports}
	// 0: the Level object.
	put_i32(&eb, -2) // class = import 1 (Level)
	put_i32(&eb, 0) // super = null
	put_i32(&eb, 0) // outer = null
	put_name_ref(&eb, 4, 0) // object_name = Level
	put_i32(&eb, 0) // archetype = null
	put_u64(&eb, 0x02000000) // object_flags
	put_i32(&eb, 64) // serial_size
	put_i32(&eb, 0) // serial_offset, patched conceptually by the payload stage
	put_u32(&eb, 0) // export_flags
	put_i32(&eb, 0) // generation net object count
	put_guid(&eb)
	put_u32(&eb, 0) // package flags
	// 1: a Brush inside the Level.
	put_i32(&eb, -2)
	put_i32(&eb, 0)
	put_i32(&eb, 1) // outer = export 0 (Level)
	put_name_ref(&eb, 5, 0) // object_name = Brush
	put_i32(&eb, 0)
	put_u64(&eb, 0)
	put_i32(&eb, 12)
	put_i32(&eb, 0)
	put_u32(&eb, 0)
	put_i32(&eb, 0)
	put_guid(&eb)
	put_u32(&eb, 0)

	add_packages: [dynamic]u8
	ab := Builder{buf = add_packages}
	put_i32(&ab, 1)
	put_fstring(&ab, "EpicMap")

	name_count := 6
	import_count := 2
	export_count := 2
	name_offset := header_fixed + len(ab.buf)
	import_offset := name_offset + len(nb.buf)
	export_offset := import_offset + len(ib.buf)
	depends_offset := export_offset + len(eb.buf)

	out := make([dynamic]u8, 0, depends_offset + 16)
	h := Builder{buf = out}
	put_u32(&h, PACKAGE_FILE_TAG)
	put_u32(&h, 0x00050240) // package 576, licensee 5
	put_i32(&h, i32(name_offset))
	put_fstring(&h, "") // folder
	put_u32(&h, PKG_COOKED | PKG_CONTAINS_MAP)
	put_i32(&h, i32(name_count))
	put_i32(&h, i32(name_offset))
	put_i32(&h, i32(export_count))
	put_i32(&h, i32(export_offset))
	put_i32(&h, i32(import_count))
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1) // generation count
	put_i32(&h, i32(export_count)) // generation export count
	put_i32(&h, i32(name_count))
	put_i32(&h, 4) // net object count
	put_i32(&h, 4701) // engine build
	put_i32(&h, 87) // cooked content version
	put_u32(&h, 0) // compression flags
	put_i32(&h, 0) // compressed chunk count
	put_i32(&h, 0) // package source
	append(&h.buf, ..ab.buf[:])

	append(&h.buf, ..nb.buf[:])
	append(&h.buf, ..ib.buf[:])
	append(&h.buf, ..eb.buf[:])
	return h.buf
}

@(test)
test_parse_synthetic_package :: proc(t: ^testing.T) {
	data := build_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	testing.expect_value(t, diag.count(&d, .Warning), 0)

	s := &pkg.summary
	testing.expect_value(t, s.tag, u32(PACKAGE_FILE_TAG))
	testing.expect_value(t, engine_version(s), i32(576))
	testing.expect_value(t, licensee_version(s), i32(5))
	testing.expect_value(t, s.engine_build, i32(4701))
	testing.expect_value(t, s.cooked_content_version, i32(87))
	testing.expect_value(t, s.total_header_size, i32(116))
	testing.expect_value(t, s.name_count, i32(6))
	testing.expect_value(t, s.import_count, i32(2))
	testing.expect_value(t, s.export_count, i32(2))
	testing.expect_value(t, s.package_flags, u32(PKG_COOKED | PKG_CONTAINS_MAP))
	testing.expect_value(t, len(s.generations), 1)
	testing.expect_value(t, s.generations[0].net_object_count, i32(4))
	testing.expect_value(t, len(s.compressed_chunks), 0)
	testing.expect_value(t, len(s.additional_packages_to_cook), 1)
	testing.expect_value(t, s.additional_packages_to_cook[0], "EpicMap")

	testing.expect_value(t, len(pkg.names), 6)
	testing.expect_value(t, pkg.names[4].text, "Level")
	testing.expect_value(t, pkg.names[5].text, "Brush")

	testing.expect_value(t, len(pkg.imports), 2)
	testing.expect_value(t, name_text(&pkg, pkg.imports[0].object_name), "Engine")
	testing.expect_value(t, name_text(&pkg, pkg.imports[1].object_name), "Level")
	testing.expect_value(t, package_index_name(&pkg, pkg.imports[1].outer_index), "Engine")

	testing.expect_value(t, len(pkg.exports), 2)
	testing.expect_value(t, name_text(&pkg, pkg.exports[0].object_name), "Level")
	testing.expect_value(t, export_class_name(&pkg, pkg.exports[0]), "Level")
	testing.expect_value(t, package_index_name(&pkg, pkg.exports[1].outer_index), "Level")
	testing.expect_value(t, pkg.exports[0].serial_size, i32(64))

	text := inspect_text(&pkg, "synthetic.ccmap")
	defer delete(text)
	testing.expect(t, strings.contains(text, "package 576 (licensee 5)"))
	testing.expect(t, strings.contains(text, "top-level:"))
	testing.expect(t, strings.contains(text, "Level"))
}

@(test)
test_name_number_suffix :: proc(t: ^testing.T) {
	data := build_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	ref := Name_Ref{index = 5, number = 3}
	testing.expect_value(t, name_text(&pkg, ref), "Brush_2")
	testing.expect_value(t, name_text(&pkg, Name_Ref{index = 99}), "<name 99 out of range>")
	testing.expect_value(t, package_index_name(&pkg, 0), "")
	testing.expect_value(t, package_index_name(&pkg, 99), "<export 98 out of range>")
}

@(test)
test_rejects_bad_tag :: proc(t: ^testing.T) {
	data := build_package()
	data[0] = 0
	data[1] = 0
	data[2] = 0
	data[3] = 0
	_, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 1)
	found := false
	for item in d.items {
		if item.code == "ue3.bad-tag" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_truncated_package_reports_error :: proc(t: ^testing.T) {
	data := build_package()
	_, d := parse(data[:40])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 1)
}

@(test)
test_table_mismatch_is_reported :: proc(t: ^testing.T) {
	// Point the export table inside the import table: the parse succeeds (the
	// records happen to be readable) but the layout is implausible, which is the
	// signal that a version gate was misapplied.
	data := build_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	check_table_bounds(&pkg, &d)
	testing.expect_value(t, diag.count(&d, .Warning), 0)
	pkg.summary.export_offset = pkg.summary.import_offset - 4
	check_table_bounds(&pkg, &d)
	testing.expect_value(t, diag.count(&d, .Warning), 1)
}

@(test)
test_unicode_name_entry :: proc(t: ^testing.T) {
	// A negative length means UTF-16 code units. Only the name table is
	// exercised: the entry parser is the same code used inside parse.
	b := Builder{}
	put_i32(&b, -6) // six UTF-16 code units, including the terminator
	for ch in ([]u16{0x42, 0x72, 0x75, 0x73, 0x68, 0x0000}) {
		append(&b.buf, u8(ch), u8(ch >> 8))
	}
	put_u64(&b, 0x11)
	r := Reader{data = b.buf[:]}
	n := read_i32(&r)
	text := read_utf16(&r, int(-n))
	testing.expect_value(t, text, "Brush")
	testing.expect_value(t, r.pos, 4 + 12)
	testing.expect_value(t, read_u64(&r), u64(0x11))
}

@(test)
test_compression_flags_text :: proc(t: ^testing.T) {
	testing.expect_value(t, compression_flags_text(0), "none")
	testing.expect_value(t, compression_flags_text(COMPRESS_ZLIB | COMPRESS_LZO), "zlib+lzo")
	testing.expect_value(t, compression_flags_text(COMPRESS_LZX), "lzx")
}

@(test)
test_package_flags_text :: proc(t: ^testing.T) {
	text := package_flags_text(PKG_COOKED | PKG_CONTAINS_MAP)
	defer delete(text)
	testing.expect(t, strings.contains(text, "cooked"))
	testing.expect(t, strings.contains(text, "contains-map"))
	testing.expect_value(t, package_flags_text(0), "")
}
