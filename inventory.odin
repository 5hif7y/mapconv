// Inventory: what a corpus is made of, group by group, with the bytes and a digest.
//
// The coverage figures of this toolkit are per file and per construct, which leaves one
// question open: are the bytes that no reader touches declared, or simply not counted?
// This command answers it. Every file of a tree falls in exactly one group by extension,
// each group states the tier it belongs to and why, and the files no reader reads are
// hashed so the declaration pins them instead of describing them.
//
// Nothing here is a reader: the groups are declarations. What is checked is what a
// declaration can be checked against -- that a file declared a binary opens as one (a PE
// header, a Bink header, a TrueType collection), and that the digests cover every byte of
// the opaque tier.
package main

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Group_Info :: struct {
	tier:   string,
	reason: string,
}

// groups is the declaration. A file whose extension is not here is reported as
// undeclared and counted in the total, so adding a format to a corpus cannot slip
// past the inventory.
groups := [?]struct {
	ext:    string,
	tier:   string,
	reason: string,
}{
	{".ccmap", "T1", "UE3 package holding a map, read object by object"},
	{".ccpk", "T2", "UE3 cooked package, read object by object"},
	{".u", "T3", "UE3 script package, read object by object"},
	{".bsp", "T4", "Source BSP, read lump by lump"},
	{".vpk", "T5", "VPK archive, tree and CRC32 of every entry"},
	{".vtf", "T6", "Valve texture, header and mip chain re-read"},
	{".vmt", "T6", "Valve material, resolved to its base texture"},
	{".dds", "T6", "texture written by this toolkit, byte compared"},
	{".dll", "T7", "binary, opaque by decision (PE header checked)"},
	{".exe", "T7", "binary, opaque by decision (PE header checked)"},
	{".bik", "T7", "Bink video, opaque by decision"},
	{".wav", "T7", "audio, opaque by decision"},
	{".mp3", "T7", "audio, opaque by decision"},
	{".ogg", "T7", "audio, opaque by decision"},
	{".ttf", "T7", "font, opaque by decision"},
	{".png", "T7", "image, opaque by decision"},
	{".tga", "T7", "image, opaque by decision"},
	{".jpg", "T7", "image, opaque by decision"},
	{".ico", "T7", "icon, opaque by decision"},
	{".dat", "T7", "support data, opaque by decision"},
	{".bin", "T7", "opaque blob by decision"},
	{".cache", "T7", "runtime cache, opaque by decision"},
	{".db", "T7", "runtime database, opaque by decision"},
	{".sav", "T7", "saved state, opaque by decision"},
	{".txt", "T7", "text, opaque by decision"},
	{".ini", "T7", "configuration, opaque by decision"},
	{".cfg", "T7", "configuration, opaque by decision"},
	{".vdf", "T7", "Steam configuration, opaque by decision"},
	{".lst", "T7", "list, opaque by decision"},
	{".res", "T7", "resource list, opaque by decision"},
	// Model geometry: this toolkit writes no models, so these are declared and not read.
	{".mdl", "T7", "model header, opaque by decision (no model writer)"},
	{".vvd", "T7", "model vertex data, opaque by decision (no model writer)"},
	{".vtx", "T7", "model index data, opaque by decision (no model writer)"},
	{".vbsp", "T7", "compiled map plane data, opaque by decision"},
	// Localisation.
	{".int", "T7", "localisation strings"},
	{".tur", "T7", "localisation strings"},
	{".bra", "T7", "localisation strings"},
	{".rus", "T7", "localisation strings"},
	{".hun", "T7", "localisation strings"},
	{".cze", "T7", "localisation strings"},
	{".pol", "T7", "localisation strings"},
	{".jpn", "T7", "localisation strings"},
	{".ita", "T7", "localisation strings"},
	{".esn", "T7", "localisation strings"},
	{".deu", "T7", "localisation strings"},
	{".fra", "T7", "localisation strings"},
	{".kor", "T7", "localisation strings"},
	{".cht", "T7", "localisation strings"},
	{".slo", "T7", "localisation strings"},
	{".com", "T7", "localisation strings"},
	// Source authoring and support files.
	{".vmf", "T7", "map source text, an input and not an artefact of the corpus"},
	{".fgd", "T7", "entity definitions"},
	{".usf", "T7", "shader source"},
	{".dsc", "T7", "material patch script"},
	{".kv", "T7", "key values"},
	{".nut", "T7", "script"},
	{".scr", "T7", "script"},
	{".gam", "T7", "game data"},
	{".nav", "T7", "navigation mesh, opaque by decision"},
	{".pcf", "T7", "particle system, opaque by decision"},
	{".prt", "T7", "particle definition"},
	{".flt", "T7", "decal/overlay definition"},
	{".rad", "T7", "radiosity data"},
	{".scd", "T7", "script data"},
	{".esp", "T7", "game data, opaque by decision"},
	{".esm", "T7", "game data, opaque by decision"},
	{".asi", "T7", "plugin binary, opaque by decision"},
	{".mhe", "T7", "binary blob, opaque by decision"},
	{".webm", "T7", "video, opaque by decision"},
	{".ttc", "T7", "font collection, opaque by decision (header checked)"},
	{".bmp", "T7", "image, opaque by decision"},
	{".icns", "T7", "icon, opaque by decision"},
	{".cur", "T7", "cursor image, opaque by decision"},
	{".image", "T7", "disk image, opaque by decision"},
	{".log", "T7", "log"},
	{".tmp", "T7", "temporary file"},
	{".id", "T7", "cache identifier"},
	{".mmt", "T7", "material script"},
	{".csv", "T7", "table"},
	{".html", "T7", "documentation"},
	{".xml", "T7", "documentation"},
	{".bat", "T7", "launcher script"},
	{".dsp", "T7", "project file"},
	{".iss", "T7", "installer script"},
	{".rc", "T7", "resource script"},
	{".inf", "T7", "driver information"},
	{".xsc", "T7", "script cache"},
	{".bsdiff", "T7", "binary patch"},
	{".mdmp", "T7", "crash dump"},
	{".wc", "T7", "support data"},
	{".dt", "T7", "support data"},
	{"", "T7", "file without an extension"},
	{".", "T7", "file without an extension"},
}


Inventory_Row :: struct {
	ext:     string,
	tier:    string,
	reason:  string,
	files:   int,
	bytes:   i64,
	header:  int, // files whose declared header was verified
	bad:     int, // files whose declared header was not there
	digest:  string,
}

// inventory_group returns the declaration of an extension, or false.
inventory_group :: proc(ext: string) -> (Group_Info, bool) {
	lower := strings.to_lower(ext)
	for g in groups {
		if g.ext == lower {
			return Group_Info{tier = g.tier, reason = g.reason}, true
		}
	}
	return {}, false
}

// binary_header_ok reports whether a file declared a binary really opens as one: a PE
// image (MZ, the PE signature at e_lfanew, a known machine and a section table that fits
// the file), or a Bink file, or a TrueType collection.
binary_header_ok :: proc(ext: string, data: []u8) -> bool {
	switch ext {
	case ".dll", ".exe":
		if len(data) < 0x40 || data[0] != 'M' || data[1] != 'Z' {
			return false
		}
		lfanew := int(u32le(data, 0x3c))
		if lfanew <= 0 || lfanew + 24 > len(data) {
			return false
		}
		if data[lfanew] != 'P' || data[lfanew + 1] != 'E' || data[lfanew + 2] != 0 || data[lfanew + 3] != 0 {
			return false
		}
		machine := u16le(data, lfanew + 4)
		if machine != 0x014c && machine != 0x8664 && machine != 0xaa64 {
			return false
		}
		sections := int(u16le(data, lfanew + 6))
		return sections > 0 && sections < 96
	case ".bik":
		return len(data) >= 4 && data[0] == 'B' && data[1] == 'I' && data[2] == 'K'
	case ".ttc", ".ttf":
		if len(data) < 4 {
			return false
		}
		tag := string(data[:4])
		return tag == "\x00\x01\x00\x00" || tag == "true" || tag == "ttcf" || tag == "OTTO"
	}
	return true
}

u32le :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24
}

u16le :: proc(data: []u8, at: int) -> u16 {
	return u16(data[at]) | u16(data[at + 1]) << 8
}

Inventory :: struct {
	rows:    [dynamic]Inventory_Row,
	paths:   [dynamic]string, // path, extension and size of every file, for the digest
	opaque:  i64,
	inscope: i64,
	unknown: i64,
}

run_inventory :: proc(args: Args, text: string) {
	root := args.input
	if root == "" {
		fmt.eprintln("inventory: --input <directory> is required")
		os.exit(2)
	}
	inv := Inventory {
		rows  = make([dynamic]Inventory_Row, 0, 64),
		paths = make([dynamic]string, 0, 8192),
	}
	defer {
		for p in inv.paths do delete(p)
		delete(inv.paths)
		for &row in inv.rows do delete(row.digest)
		delete(inv.rows)
	}
	files := 0
	walk_inventory(&inv, root, &files)

	slice.sort_by(inv.rows[:], proc(a, b: Inventory_Row) -> bool {
		return a.bytes > b.bytes
	})
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "inventory: %s\n", root)
	fmt.sbprintf(&b, "  %-8s %7s %16s %-4s %s\n", "ext", "files", "bytes", "tier", "what")
	for row in inv.rows {
		fmt.sbprintf(&b, "  %-8s %7d %16d %-4s %s", row.ext, row.files, row.bytes, row.tier, row.reason)
		if row.header > 0 || row.bad > 0 {
			fmt.sbprintf(&b, " [headers %d ok, %d bad]", row.header, row.bad)
		}
		if row.tier == "T7" {
			fmt.sbprintf(&b, " sha256 %s", row.digest)
		}
		strings.write_byte(&b, '\n')
	}
	total := inv.opaque + inv.inscope + inv.unknown
	fmt.sbprintf(&b, "  %-8s %7d %16d\n", "total", files, total)
	fmt.sbprintf(&b, "in scope:  %16d B\n", inv.inscope)
	fmt.sbprintf(&b, "opaque:    %16d B (%d%%) declared, digest %s\n",
		inv.opaque, 100 * inv.opaque / max(1, total), inventory_digest(inv))
	if inv.unknown > 0 {
		fmt.sbprintf(&b, "undeclared: %d B in files whose extension is not in the table\n", inv.unknown)
	}
	out := strings.to_string(b)
	if !args.quiet {
		fmt.print(out)
	}
}

// inventory_digest hashes the declaration itself: every opaque file's path, size and
// content digest, in path order. It pins the tier without storing it.
// digest_hex owns its result: the builder's buffer becomes the string, so the caller
// frees it with delete like any other string.
digest_hex :: proc(bytes: []u8) -> string {
	b := strings.builder_make()
	for byte in bytes {
		fmt.sbprintf(&b, "%02x", byte)
	}
	return strings.to_string(b)
}

// digest_combine folds a file digest into the group's digest, so a group pins its files
// in the order they are walked.
digest_combine :: proc(previous: string, next: string) -> string {
	if previous == "" {
		return strings.clone(next)
	}
	joined := fmt.aprintf("%s%s", previous, next)
	delete(previous)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)joined)
	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, sum[:])
	delete(joined)
	return digest_hex(sum[:])
}

inventory_digest :: proc(inv: Inventory) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	for row in inv.rows {
		if row.tier != "T7" {
			continue
		}
		sha2.update(&ctx, transmute([]u8)row.digest)
		sha2.update(&ctx, []u8{'\n'})
	}
	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, sum[:])
	return digest_hex(sum[:])
}

walk_inventory :: proc(inv: ^Inventory, dir: string, files: ^int) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintln("inventory: cannot read", dir)
		return
	}
	defer delete(entries)
	for entry in entries {
		if entry.name == "." || entry.name == ".." {
			continue
		}
		path := fmt.aprintf("%s/%s", dir, entry.name)
		if entry.type == .Directory {
			walk_inventory(inv, path, files)
			delete(path)
			continue
		}
		inventory_file(inv, path, files)
		delete(path)
	}
}

inventory_file :: proc(inv: ^Inventory, path: string, files: ^int) {
	ext := filepath.ext(path)
	stat_info, stat_err := os.stat(path, context.allocator)
	if stat_err != nil {
		return
	}
	size := i64(stat_info.size)
	files^ += 1

	info, declared := inventory_group(ext)
	if !declared {
		// An extension the table does not know is counted, not ignored: a new format in
		// a corpus has to show up as a number the declaration does not explain.
		inv.unknown += size
		return
	}
	row_index := inventory_row(inv, ext, info)
	row := &inv.rows[row_index]
	row.files += 1
	row.bytes += size

	if info.tier != "T7" {
		// In-scope bytes are read by their own reader; reading them here would say
		// nothing that reader does not already say.
		inv.inscope += size
		return
	}

	// The opaque tier is read once, because its digest is the whole point of the
	// declaration: it pins the bytes instead of describing them.
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		row.files -= 1
		row.bytes -= size
		files^ -= 1
		return
	}
	defer delete(data)
	inv.opaque += size
	if ext == ".dll" || ext == ".exe" || ext == ".bik" || ext == ".ttc" || ext == ".ttf" {
		if binary_header_ok(ext, data) {
			row.header += 1
		} else {
			row.bad += 1
		}
	}
	file_ctx: sha2.Context_256
	sha2.init_256(&file_ctx)
	sha2.update(&file_ctx, data)
	file_sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&file_ctx, file_sum[:])
	hex := digest_hex(file_sum[:])
	row.digest = digest_combine(row.digest, hex)
	entry := fmt.aprintf("%s\t%d\t%s", path, size, hex)
	delete(hex)
	append(&inv.paths, entry)
}

inventory_row :: proc(inv: ^Inventory, ext: string, info: Group_Info) -> int {
	for row, index in inv.rows {
		if row.ext == ext {
			return index
		}
	}
	row := Inventory_Row {
		ext    = strings.clone(ext),
		tier   = info.tier,
		reason = info.reason,
	}
	append(&inv.rows, row)
	return len(inv.rows) - 1
}
