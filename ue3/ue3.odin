// Package ue3 reads Unreal Engine 3 package files (.ccmap in CrimeCraft).
//
// This is the entry point to the Unreal -> Source direction. The first stage,
// implemented here, reads the package summary and the three tables that describe
// every object in the package: names, imports and exports. Object payloads are
// reached later through the export table's serial offsets.
//
// The layout is documented byte by byte, with the offsets verified against all
// 218 CrimeCraft map packages, in docs/formats/ue3-package.md. Those packages
// are all version 576/5 (engine build 4701, cooked content 87) and store their
// header uncompressed; compressed chunk payloads are reported but not decoded.
package ue3

import "core:fmt"
import "core:mem"
import "core:strings"
import "../diag"

// Magic at offset 0. The byte-swapped form appears in packages saved on a
// big-endian host; CrimeCraft's are little-endian.
PACKAGE_FILE_TAG :: 0x9E2A83C1
PACKAGE_FILE_TAG_SWAPPED :: 0xC1832A9E

// Version gates from Development/Src/Core/Inc/UnObjVer.h (UE3 10897). The map
// packages are 576, so only the thresholds below the verified version apply;
// they are listed so later versions fail loudly instead of silently misreading.
VER_ADDITIONAL_COOK_PACKAGE_SUMMARY :: 516
VER_REMOVED_COMPONENT_MAP :: 543
VER_ASSET_THUMBNAILS_IN_PACKAGES :: 584
VER_ADDED_CROSSLEVEL_REFERENCES :: 623
// FPropertyTag conditionals (Core/Inc/UnPropertyTag.h).
VER_BYTEPROP_SERIALIZE_ENUM :: 633
VER_PROPERTYTAG_BOOL_OPTIMIZATION :: 673
// FStateFrame prelude (UObject::Serialize before SerializeNetIndex).
VER_REDUCED_STATEFRAME_LATENTACTION_SIZE :: 566
VER_TEXTURE_PREALLOCATION :: 767

// Package flags (EPackageFlags). Only the ones worth showing are named.
PKG_ALLOW_DOWNLOAD :: 0x00000001
PKG_COOKED :: 0x00000008
PKG_CONTAINS_MAP :: 0x00020000
PKG_DISALLOW_LAZY_LOADING :: 0x00080000
PKG_REQUIRE_IMPORTS_ALREADY_LOADED :: 0x00800000
PKG_STORE_COMPRESSED :: 0x02000000
PKG_STORE_FULLY_COMPRESSED :: 0x04000000
PKG_FILTER_EDITOR_ONLY :: 0x80000000

// Compression flags (ECompressionFlags) stored in the summary.
COMPRESS_ZLIB :: 0x01
COMPRESS_LZO :: 0x02
COMPRESS_LZX :: 0x04

// Guid is 16 opaque bytes. UE3 serializes FGuid as four little-endian words on
// PC, which is the same byte order, so the raw copy is enough for display and
// equality.
Guid :: struct {
	bytes: [16]u8,
}

guid_u32 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

guid_string :: proc(g: Guid) -> string {
	bytes := g.bytes
	// FGuid::ToString prints the four serialized words, in order. The bytes are
	// little-endian, so each word reads back reversed from the file.
	return fmt.aprintf(
		"%08X-%08X-%08X-%08X",
		guid_u32(bytes[:], 0),
		guid_u32(bytes[:], 4),
		guid_u32(bytes[:], 8),
		guid_u32(bytes[:], 12),
	)
}

Generation :: struct {
	export_count:     i32,
	name_count:       i32,
	net_object_count: i32,
}

CompressedChunk :: struct {
	uncompressed_offset: i32,
	uncompressed_size:   i32,
	compressed_offset:   i32,
	compressed_size:     i32,
}

// Summary mirrors FPackageFileSummary (UnLinker.cpp:377 in the UE3 fork).
// Optional fields are zero or -1 when the package version predates them.
Summary :: struct {
	tag: u32,
	// Engine version in the low 16 bits, licensee version in the high 16.
	package_version:   u32,
	total_header_size: i32,
	folder_name:       string,
	package_flags:     u32,
	name_count:        i32,
	name_offset:       i32,
	export_count:      i32,
	export_offset:     i32,
	import_count:      i32,
	import_offset:     i32,
	depends_offset:    i32,
	// Added in 623 (cross-level references); -1 when absent.
	import_export_guids_offset: i32,
	import_guids_count:         i32,
	export_guids_count:         i32,
	// Added in 584 (asset thumbnails); -1 when absent.
	thumbnail_table_offset: i32,
	guid:                   Guid,
	generations:            []Generation,
	// Engine build number that saved the package (4701), not the package format.
	engine_build:           i32,
	cooked_content_version: i32,
	compression_flags:      u32,
	compressed_chunks:      []CompressedChunk,
	package_source:         i32,
	additional_packages_to_cook: []string,
	// Added in 767 (texture preallocation); only the count is kept for now.
	texture_allocation_count: i32,
}

// engine_version mirrors FPackageFileSummary::GetFileVersion: the package
// format version, which drives every conditional in the file layout.
engine_version :: proc(s: ^Summary) -> i32 {
	return i32(s.package_version & 0xffff)
}

licensee_version :: proc(s: ^Summary) -> i32 {
	return i32((s.package_version >> 16) & 0xffff)
}

// Name is one entry of the package name table. `flags` is the EObjectFlags value
// written after the string. The fork uses 64-bit flags: reading 4 bytes
// misaligns the second entry of every package (verified against game data).
Name :: struct {
	text:  string,
	flags: u64,
}

// Name_Ref is an FName as stored in the tables: an index into the name table plus
// a disambiguating number for generated names ("Brush2").
Name_Ref :: struct {
	index:  i32,
	number: i32,
}

// Import is one FObjectImport. The class of an object is looked up through
// class_name; class_package says which package defines that class.
Import :: struct {
	class_package: Name_Ref,
	class_name:    Name_Ref,
	outer_index:   i32,
	object_name:   Name_Ref,
}

// Export is one FObjectExport. GenerationNetObjectCount is serialized inline as a
// TArray<INT>; the 543 version gate for the legacy component map is handled in
// parse_exports.
Export :: struct {
	class_index:     i32,
	super_index:     i32,
	outer_index:     i32,
	object_name:     Name_Ref,
	archetype_index: i32,
	object_flags:    u64,
	serial_size:     i32,
	serial_offset:   i32,
	export_flags:    u32,
	generation_net_object_count: []i32,
	package_guid:    Guid,
	package_flags:   u32,
}

Package :: struct {
	// data is borrowed; ANSI name strings alias it. UTF-16 names are allocated.
	data:    []u8,
	summary: Summary,
	names:   []Name,
	imports: []Import,
	exports: []Export,
	// End offsets measured while parsing, used to catch layout drift.
	names_end:   int,
	imports_end: int,
	exports_end: int,
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

Reader :: struct {
	data: []u8,
	pos:  int,
	// limit bounds reads to one export payload; 0 means the whole file.
	limit:   int,
	failed:  bool,
	message: string,
}

reader_fail :: proc(r: ^Reader, message: string) {
	if !r.failed {
		r.failed = true
		r.message = message
	}
}

need :: proc(r: ^Reader, n: int) -> bool {
	if r.failed {
		return false
	}
	end := len(r.data)
	if r.limit > 0 && r.limit < end {
		end = r.limit
	}
	// A previous field read through an overflowing count can leave pos
	// negative; without this guard the index wraps and the process dies with an
	// access violation instead of reporting a diagnostic.
	if n < 0 || r.pos < 0 || r.pos + n > end {
		reader_fail(r, fmt.aprintf("read of %d bytes at offset %d exceeds the available data (%d bytes)", n, r.pos, end))
		return false
	}
	return true
}

read_u8 :: proc(r: ^Reader) -> u8 {
	if !need(r, 1) {
		return 0
	}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

read_u16 :: proc(r: ^Reader) -> u16 {
	if !need(r, 2) {
		return 0
	}
	v := u16(r.data[r.pos]) | u16(r.data[r.pos + 1]) << 8
	r.pos += 2
	return v
}

read_u32 :: proc(r: ^Reader) -> u32 {
	if !need(r, 4) {
		return 0
	}
	v :=
		u32(r.data[r.pos]) |
		u32(r.data[r.pos + 1]) << 8 |
		u32(r.data[r.pos + 2]) << 16 |
		u32(r.data[r.pos + 3]) << 24
	r.pos += 4
	return v
}

read_i32 :: proc(r: ^Reader) -> i32 {
	return i32(read_u32(r))
}

read_f32 :: proc(r: ^Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

read_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(read_u32(r))
	hi := u64(read_u32(r))
	return lo | hi << 32
}

read_f64 :: proc(r: ^Reader) -> f64 {
	return transmute(f64)read_u64(r)
}

read_guid :: proc(r: ^Reader) -> Guid {
	g: Guid
	if !need(r, 16) {
		return g
	}
	copy(g.bytes[:], r.data[r.pos:r.pos + 16])
	r.pos += 16
	return g
}

read_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	if !need(r, n) {
		return nil
	}
	slice := r.data[r.pos:r.pos + n]
	r.pos += n
	return slice
}

// read_fstring reads an FString: a length followed by ANSI bytes (the length
// includes the terminator) or UTF-16 code units when the length is negative.
// ANSI strings alias `data`; UTF-16 strings are built and cloned.
read_fstring :: proc(r: ^Reader) -> string {
	n := read_i32(r)
	if r.failed || n == 0 {
		return ""
	}
	if n > 0 {
		return read_ansi(r, int(n))
	}
	return read_utf16(r, int(-n))
}

// read_ansi reads `n` ANSI bytes and strips trailing NULs. The result aliases
// the file buffer.
read_ansi :: proc(r: ^Reader, n: int) -> string {
	bytes := read_bytes(r, n)
	if r.failed {
		return ""
	}
	end := len(bytes)
	for end > 0 && bytes[end - 1] == 0 {
		end -= 1
	}
	return string(bytes[:end])
}

// read_utf16 reads `units` UTF-16 code units (the FString convention for a
// negative length) and allocates the result.
read_utf16 :: proc(r: ^Reader, units: int) -> string {
	bytes := read_bytes(r, units * 2)
	if r.failed {
		return ""
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0..<units {
		code := u16(bytes[i * 2]) | u16(bytes[i * 2 + 1]) << 8
		if code == 0 {
			break
		}
		strings.write_rune(&b, rune(code))
	}
	return strings.clone(strings.to_string(b))
}

read_name_ref :: proc(r: ^Reader) -> Name_Ref {
	return Name_Ref{read_i32(r), read_i32(r)}
}

// seek moves the reader to an absolute offset, reporting a diagnostic-friendly
// failure when the offset is outside the file.
seek :: proc(r: ^Reader, offset: i32) -> bool {
	if r.failed {
		return false
	}
	if offset < 0 || int(offset) > len(r.data) {
		reader_fail(r, fmt.aprintf("table offset %d is outside the file (%d bytes)", offset, len(r.data)))
		return false
	}
	r.pos = int(offset)
	return true
}

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

// parse reads the summary and the name, import and export tables. It never
// panics: a malformed file yields an error diagnostic and a zero Package.
parse :: proc(data: []u8, allocator := context.allocator) -> (pkg: Package, d: diag.Diagnostics) {
	d = diag.init()
	pkg.data = data

	r := Reader{data = data}
	s := &pkg.summary

	s.tag = read_u32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if s.tag == PACKAGE_FILE_TAG_SWAPPED {
		diag.err(&d, "ue3.byte-swapped", "big-endian package; only little-endian packages are supported")
		return
	}
	if s.tag != PACKAGE_FILE_TAG {
		diag.err(&d, "ue3.bad-tag", fmt.aprintf("expected package tag 0x%08X, found 0x%08X", PACKAGE_FILE_TAG, s.tag))
		return
	}

	s.package_version = read_u32(&r)
	s.total_header_size = read_i32(&r)
	s.folder_name = read_fstring(&r)
	s.package_flags = read_u32(&r)

	s.name_count = read_i32(&r)
	s.name_offset = read_i32(&r)
	s.export_count = read_i32(&r)
	s.export_offset = read_i32(&r)
	s.import_count = read_i32(&r)
	s.import_offset = read_i32(&r)
	s.depends_offset = read_i32(&r)

	version := engine_version(s)
	if version != 576 {
		diag.warn(
			&d,
			"ue3.unverified-version",
			fmt.aprintf(
				"package version %d/%d was not verified against game data; parsing with the 576 layout",
				version,
				licensee_version(s),
			),
		)
	}

	if version >= VER_ADDED_CROSSLEVEL_REFERENCES {
		s.import_export_guids_offset = read_i32(&r)
		s.import_guids_count = read_i32(&r)
		s.export_guids_count = read_i32(&r)
	} else {
		s.import_export_guids_offset = -1
	}
	if version >= VER_ASSET_THUMBNAILS_IN_PACKAGES {
		s.thumbnail_table_offset = read_i32(&r)
	} else {
		s.thumbnail_table_offset = -1
	}

	s.guid = read_guid(&r)
	generation_count := read_i32(&r)
	if generation_count < 0 || generation_count > 1024 {
		reader_fail(&r, fmt.aprintf("implausible generation count %d", generation_count))
	}
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	s.generations = make([]Generation, int(generation_count), allocator)
	for i in 0..<int(generation_count) {
		s.generations[i] = Generation{read_i32(&r), read_i32(&r), read_i32(&r)}
	}

	s.engine_build = read_i32(&r)
	s.cooked_content_version = read_i32(&r)
	s.compression_flags = read_u32(&r)

	chunk_count := read_i32(&r)
	if chunk_count < 0 || chunk_count > 1_000_000 {
		reader_fail(&r, fmt.aprintf("implausible compressed chunk count %d", chunk_count))
	}
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	s.compressed_chunks = make([]CompressedChunk, int(chunk_count), allocator)
	for i in 0..<int(chunk_count) {
		s.compressed_chunks[i] = CompressedChunk{read_i32(&r), read_i32(&r), read_i32(&r), read_i32(&r)}
	}
	s.package_source = read_i32(&r)

	if version >= VER_ADDITIONAL_COOK_PACKAGE_SUMMARY {
		count := read_i32(&r)
		if count < 0 || count > 1_000_000 {
			reader_fail(&r, fmt.aprintf("implausible additional package count %d", count))
		}
		if !r.failed {
			s.additional_packages_to_cook = make([]string, int(count), allocator)
			for i in 0..<int(count) {
				s.additional_packages_to_cook[i] = read_fstring(&r)
			}
		}
	}

	if version >= VER_TEXTURE_PREALLOCATION {
		count := read_i32(&r)
		if count < 0 || count > 1_000_000 {
			reader_fail(&r, fmt.aprintf("implausible texture allocation count %d", count))
		}
		if !r.failed {
			s.texture_allocation_count = count
			// FTextureAllocations::FTextureType: 5 ints plus a TArray<INT>.
			for _ in 0..<int(count) {
				_ = read_i32(&r) // size_x
				_ = read_i32(&r) // size_y
				_ = read_i32(&r) // num_mips
				_ = read_u32(&r) // format
				_ = read_u32(&r) // tex create flags
				indices := read_i32(&r)
				if indices < 0 || indices > 1_000_000 {
					reader_fail(&r, "implausible texture export index count")
					break
				}
				_ = read_bytes(&r, int(indices) * 4)
			}
		}
	}

	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}

	if len(s.compressed_chunks) > 0 {
		diag.info(
			&d,
			"ue3.compression-present",
			fmt.aprintf(
				"%d compressed chunk(s), flags 0x%X: header tables are readable, object payloads are not decompressed yet",
				len(s.compressed_chunks),
				s.compression_flags,
			),
		)
	}

	parse_names(&pkg, &r, &d, allocator)
	if diag.has_errors(&d) {
		return
	}
	parse_imports(&pkg, &r, &d, allocator)
	if diag.has_errors(&d) {
		return
	}
	parse_exports(&pkg, &r, &d, allocator, version)
	if diag.has_errors(&d) {
		return
	}
	check_table_bounds(&pkg, &d)
	return
}

parse_names :: proc(pkg: ^Package, r: ^Reader, d: ^diag.Diagnostics, allocator: mem.Allocator) {
	s := &pkg.summary
	if s.name_count < 0 || s.name_count > 4_000_000 {
		diag.err(d, "ue3.bad-name-table", fmt.aprintf("implausible name count %d", s.name_count))
		return
	}
	if !seek(r, s.name_offset) {
		diag.err(d, "ue3.truncated", r.message)
		return
	}
	pkg.names = make([]Name, int(s.name_count), allocator)
	for i in 0..<int(s.name_count) {
		n := read_i32(r)
		if r.failed {
			diag.err(d, "ue3.truncated", r.message)
			return
		}
		text: string
		if n == 0 {
			text = ""
		} else if n > 0 {
			bytes := read_bytes(r, int(n))
			if r.failed {
				diag.err(d, "ue3.truncated", r.message)
				return
			}
			end := len(bytes)
			for end > 0 && bytes[end - 1] == 0 {
				end -= 1
			}
			text = string(bytes[:end])
		} else {
			text = read_utf16(r, int(-n))
			if r.failed {
				diag.err(d, "ue3.truncated", r.message)
				return
			}
		}
		flags := read_u64(r)
		if r.failed {
			diag.err(d, "ue3.truncated", r.message)
			return
		}
		pkg.names[i] = Name{text, flags}
	}
	pkg.names_end = r.pos
}

parse_imports :: proc(pkg: ^Package, r: ^Reader, d: ^diag.Diagnostics, allocator: mem.Allocator) {
	s := &pkg.summary
	if s.import_count < 0 || s.import_count > 4_000_000 {
		diag.err(d, "ue3.bad-import-table", fmt.aprintf("implausible import count %d", s.import_count))
		return
	}
	if !seek(r, s.import_offset) {
		diag.err(d, "ue3.truncated", r.message)
		return
	}
	pkg.imports = make([]Import, int(s.import_count), allocator)
	for i in 0..<int(s.import_count) {
		imp: Import
		imp.class_package = read_name_ref(r)
		imp.class_name = read_name_ref(r)
		imp.outer_index = read_i32(r)
		imp.object_name = read_name_ref(r)
		if r.failed {
			diag.err(d, "ue3.truncated", r.message)
			return
		}
		pkg.imports[i] = imp
	}
	pkg.imports_end = r.pos
}

parse_exports :: proc(pkg: ^Package, r: ^Reader, d: ^diag.Diagnostics, allocator: mem.Allocator, version: i32) {
	s := &pkg.summary
	if s.export_count < 0 || s.export_count > 4_000_000 {
		diag.err(d, "ue3.bad-export-table", fmt.aprintf("implausible export count %d", s.export_count))
		return
	}
	if !seek(r, s.export_offset) {
		diag.err(d, "ue3.truncated", r.message)
		return
	}
	pkg.exports = make([]Export, int(s.export_count), allocator)
	for i in 0..<int(s.export_count) {
		e: Export
		e.class_index = read_i32(r)
		e.super_index = read_i32(r)
		e.outer_index = read_i32(r)
		e.object_name = read_name_ref(r)
		e.archetype_index = read_i32(r)
		e.object_flags = read_u64(r)
		e.serial_size = read_i32(r)
		e.serial_offset = read_i32(r)

		if version < VER_REMOVED_COMPONENT_MAP {
			// Legacy component map: TMap<FName, INT>.
			count := read_i32(r)
			if count < 0 || count > 1_000_000 {
				reader_fail(r, fmt.aprintf("implausible component map count %d in export %d", count, i))
			}
			for _ in 0..<int(count) {
				_ = read_name_ref(r)
				_ = read_i32(r)
			}
		}

		e.export_flags = read_u32(r)
		net_count := read_i32(r)
		if net_count < 0 || net_count > 1024 {
			reader_fail(r, fmt.aprintf("implausible net object count %d in export %d", net_count, i))
		}
		if !r.failed {
			e.generation_net_object_count = make([]i32, int(net_count), allocator)
			for j in 0..<int(net_count) {
				e.generation_net_object_count[j] = read_i32(r)
			}
		}
		e.package_guid = read_guid(r)
		e.package_flags = read_u32(r)
		if r.failed {
			diag.err(d, "ue3.truncated", r.message)
			return
		}
		pkg.exports[i] = e
	}
	pkg.exports_end = r.pos
}

// check_table_bounds verifies that the tables are laid out back to back, which
// is how every verified package stores them. A mismatch usually means the
// version layout is wrong; it is reported as a warning so inspection still works.
check_table_bounds :: proc(pkg: ^Package, d: ^diag.Diagnostics) {
	s := &pkg.summary
	// Every verified package lays the tables back to back; each end offset is
	// measured during parsing, so a mismatch means a wrong field size or a
	// misapplied version gate, not merely a different order.
	if s.name_count > 0 && pkg.names_end != int(s.import_offset) {
		diag.warn(
			d,
			"ue3.table-mismatch",
			fmt.aprintf(
				"names end at %d but the import table starts at %d (difference %+d bytes)",
				pkg.names_end,
				s.import_offset,
				pkg.names_end - int(s.import_offset),
			),
		)
	}
	if s.import_count > 0 && pkg.imports_end != int(s.export_offset) {
		diag.warn(
			d,
			"ue3.table-mismatch",
			fmt.aprintf(
				"imports end at %d but the export table starts at %d (difference %+d bytes)",
				pkg.imports_end,
				s.export_offset,
				pkg.imports_end - int(s.export_offset),
			),
		)
	}
	if s.export_count > 0 && s.depends_offset > 0 && pkg.exports_end != int(s.depends_offset) {
		diag.warn(
			d,
			"ue3.table-mismatch",
			fmt.aprintf(
				"exports end at %d but the depends map starts at %d (difference %+d bytes)",
				pkg.exports_end,
				s.depends_offset,
				pkg.exports_end - int(s.depends_offset),
			),
		)
	}
}

// ---------------------------------------------------------------------------
// Names and package indices
// ---------------------------------------------------------------------------

// name_text resolves a name reference the way FName::ToString does: the entry
// text plus "_<n>" when the reference carries a number (internal number - 1).
name_text :: proc(pkg: ^Package, ref: Name_Ref) -> string {
	if ref.index < 0 || int(ref.index) >= len(pkg.names) {
		return fmt.aprintf("<name %d out of range>", ref.index)
	}
	base := pkg.names[ref.index].text
	if ref.number == 0 {
		return base
	}
	return fmt.aprintf("%s_%d", base, ref.number - 1)
}

Package_Index_Kind :: enum {
	Null,
	Export,
	Import,
}

package_index_kind :: proc(value: i32) -> Package_Index_Kind {
	if value == 0 {
		return .Null
	}
	return value > 0 ? .Export : .Import
}

// package_index_name resolves an FPackageIndex: positive values are export
// indices plus one, negative values are import indices plus one, negated.
package_index_name :: proc(pkg: ^Package, value: i32) -> string {
	switch package_index_kind(value) {
	case .Null:
		return ""
	case .Export:
		index := int(value) - 1
		if index < 0 || index >= len(pkg.exports) {
			return fmt.aprintf("<export %d out of range>", index)
		}
		return name_text(pkg, pkg.exports[index].object_name)
	case .Import:
		index := int(-value) - 1
		if index < 0 || index >= len(pkg.imports) {
			return fmt.aprintf("<import %d out of range>", index)
		}
		return name_text(pkg, pkg.imports[index].object_name)
	}
	return ""
}

// export_class_name is the class of an export. In a cooked package the class is
// normally an import, but CrimeCraft also ships exports whose class index is
// null: those are the package's own class objects, so they are labelled instead
// of being left with an empty name (an empty row cannot be attributed).
export_class_name :: proc(pkg: ^Package, e: Export) -> string {
	if e.class_index == 0 {
		return "(null class)"
	}
	return package_index_name(pkg, e.class_index)
}

// import_class_name is the class of an import, resolved the same way.
import_class_name :: proc(pkg: ^Package, i: Import) -> string {
	return name_text(pkg, i.class_name)
}

// package_flags_text renders the known EPackageFlags bits.
package_flags_text :: proc(flags: u32) -> string {
	b := strings.builder_make()
	known := [?]struct {
		bit:  u32,
		name: string,
	}{
		{PKG_ALLOW_DOWNLOAD, "allow-download"},
		{PKG_COOKED, "cooked"},
		{PKG_CONTAINS_MAP, "contains-map"},
		{PKG_DISALLOW_LAZY_LOADING, "disallow-lazy-loading"},
		{PKG_REQUIRE_IMPORTS_ALREADY_LOADED, "require-imports-already-loaded"},
		{PKG_STORE_COMPRESSED, "store-compressed"},
		{PKG_STORE_FULLY_COMPRESSED, "store-fully-compressed"},
		{PKG_FILTER_EDITOR_ONLY, "filter-editor-only"},
	}
	for item in known {
		if flags & item.bit != 0 {
			if strings.builder_len(b) > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, item.name)
		}
	}
	unknown := flags
	for item in known {
		unknown &= ~item.bit
	}
	if unknown != 0 {
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "0x%08X", unknown)
	}
	return strings.clone(strings.to_string(b))
}

compression_flags_text :: proc(flags: u32) -> string {
	if flags == 0 {
		return "none"
	}
	b := strings.builder_make()
	if flags & COMPRESS_ZLIB != 0 {
		strings.write_string(&b, "zlib")
	}
	if flags & COMPRESS_LZO != 0 {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, '+')
		}
		strings.write_string(&b, "lzo")
	}
	if flags & COMPRESS_LZX != 0 {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, '+')
		}
		strings.write_string(&b, "lzx")
	}
	return strings.clone(strings.to_string(b))
}

// read_name_ref_at reads an FName that was skipped over.
read_name_ref_at :: proc(data: []u8, at: int) -> Name_Ref {
	if at < 0 || at + 8 > len(data) {
		return Name_Ref{}
	}
	return Name_Ref{index = i32(u32(data[at]) | u32(data[at+1]) << 8 | u32(data[at+2]) << 16 | u32(data[at+3]) << 24),
		number = i32(u32(data[at+4]) | u32(data[at+5]) << 8 | u32(data[at+6]) << 16 | u32(data[at+7]) << 24)}
}
