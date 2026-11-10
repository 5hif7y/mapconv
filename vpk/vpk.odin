// VPK: the archives a Source game ships its assets in.
//
// A version 2 directory file starts with a 28 byte header and then the tree, which
// is nested: an extension, then each directory of that extension, then each file
// of that directory. An empty name closes the list of files of a directory, an
// empty directory closes the extension and an empty extension closes the tree. A
// file without an extension is stored under a single space.
//
// The payload of an entry lives in a numbered archive next to the directory file
// (`<stem>_NNN.vpk`), or inside the directory file itself when the archive field is
// 0x7FFF. Version 2 stores bytes uncompressed, so the CRC32 the tree records is the
// whole content check.
package vpk

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../diag"

HEADER_BYTES :: 28
RECORD_BYTES :: 18
ARCHIVE_IN_DIR :: 0x7FFF

Entry :: struct {
	ext:     string,
	dir:     string,
	name:    string,
	crc:     u32,
	preload: u16,
	archive: u16,
	offset:  u32,
	length:  u32,
}

Tree :: struct {
	entries:   []Entry,
	by_path:   map[string]int,
	dir_path:  string, // the directory file this tree came from
	tree_size: u32, // bytes of tree after the header
}

// parse reads a directory file and its tree. The caller owns the result through
// destroy.
parse :: proc(dir_path: string, allocator := context.allocator) -> (tree: Tree, d: diag.Diagnostics) {
	d = diag.init()
	data, read_err := os.read_entire_file(dir_path, allocator)
	if read_err != nil {
		diag.err(&d, "vpk.unreadable", fmt.aprintf("%s could not be read", dir_path))
		return
	}
	defer delete(data)
	tree, d = parse_bytes(data, allocator)
	tree.dir_path = strings.clone(dir_path, allocator)
	if diag.has_errors(&d) {
		return
	}
	return
}

destroy :: proc(tree: ^Tree) {
	for key in tree.by_path {
		delete(key)
	}
	delete(tree.by_path)
	for entry in tree.entries {
		delete(entry.ext)
		delete(entry.dir)
		delete(entry.name)
	}
	delete(tree.entries)
	delete(tree.dir_path)
	tree^ = {}
}

// parse_bytes reads a tree from memory, which is what the tests build.
parse_bytes :: proc(data: []u8, allocator := context.allocator) -> (tree: Tree, d: diag.Diagnostics) {
	d = diag.init()
	if len(data) < HEADER_BYTES {
		diag.err(&d, "vpk.short", "shorter than a VPK header")
		return
	}
	signature := read_u32(data, 0)
	version := read_u32(data, 4)
	tree_size := int(read_u32(data, 8))
	if signature != 0x55AA1234 || version != 2 {
		diag.err(&d, "vpk.version", fmt.aprintf("not a version 2 VPK (signature 0x%08X, version %d)", signature, version))
		return
	}
	end := HEADER_BYTES + tree_size
	if end > len(data) {
		diag.err(&d, "vpk.tree-outside", "the tree lies outside the file")
		return
	}
	entries := make([dynamic]Entry, 0, 1024, allocator)
	by_path := make(map[string]int, 1024, allocator)
	position := HEADER_BYTES
	failed := false
	text := proc(data: []u8, position: ^int, end: int) -> (value: string, ok: bool) {
		if position^ >= end {
			return "", false
		}
		for at := position^; at < end; at += 1 {
			if data[at] == 0 {
				value = string(data[position^:at])
				position^ = at + 1
				return value, true
			}
		}
		return "", false
	}
	ext, ext_ok := text(data, &position, end)
	for ext_ok && ext != "" && !failed {
		directory, directory_ok := text(data, &position, end)
		for directory_ok && directory != "" && !failed {
			for {
				name, name_ok := text(data, &position, end)
				if !name_ok {
					diag.err(&d, "vpk.truncated", fmt.aprintf("the tree ends inside an entry (%d read)", len(entries)))
					failed = true
					break
				}
				if name == "" {
					break
				}
				if position + RECORD_BYTES > end {
					diag.err(&d, "vpk.record", "an entry record starts past the tree")
					failed = true
					break
				}
				terminator := read_u16(data, position + 16)
				if terminator != 0xFFFF {
					diag.err(&d, "vpk.terminator", fmt.aprintf("entry %d has terminator 0x%04X", len(entries), terminator))
					failed = true
					break
				}
				entry := Entry {
					ext     = strings.clone(ext == " " ? "" : ext, allocator),
					dir     = strings.clone(directory, allocator),
					name    = strings.clone(name, allocator),
					crc     = read_u32(data, position),
					preload = read_u16(data, position + 4),
					archive = read_u16(data, position + 6),
					offset  = read_u32(data, position + 8),
					length  = read_u32(data, position + 12),
				}
				position += RECORD_BYTES
				append(&entries, entry)
				by_path[lookup_key(entry, allocator)] = len(entries) - 1
			}
			directory, directory_ok = text(data, &position, end)
		}
		ext, ext_ok = text(data, &position, end)
	}
	if !failed && position != end {
		diag.err(&d, "vpk.tree-short", fmt.aprintf("the tree ends %d bytes short", end - position))
		failed = true
	}
	if failed {
		for entry in entries {
			delete(entry.ext)
			delete(entry.dir)
			delete(entry.name)
		}
		delete(entries)
		for key in by_path {
			delete(key)
		}
		delete(by_path)
		return
	}
	tree.entries = entries[:]
	tree.by_path = by_path
	tree.tree_size = u32(tree_size)
	return
}

// lookup_key is the canonical form of a path inside the tree: extension, directory
// and name in lower case, because Source looks assets up case insensitively.
lookup_key :: proc(entry: Entry, allocator := context.allocator) -> string {
	path := fmt.aprintf("%s/%s.%s", entry.dir, entry.name, entry.ext, allocator = allocator)
	lower := strings.to_lower(path, allocator)
	delete(path)
	return lower
}

read_u16 :: proc(data: []u8, at: int) -> u16 {
	return u16(data[at]) | u16(data[at + 1]) << 8
}

read_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24
}

// lookup finds an entry by a path such as "materials/de_dust/wall.vmt".
lookup :: proc(tree: ^Tree, path: string) -> (entry: Entry, index: int, ok: bool) {
	// The key is built in the temporary allocator: a lookup happens in a loop over
	// hundreds of names and does not outlive the call.
	key := strings.to_lower(path, context.temp_allocator)
	at, found := tree.by_path[key]
	if !found {
		return {}, 0, false
	}
	return tree.entries[at], at, true
}

// archive_path names the numbered archive that holds an entry, or the directory
// file itself when the entry is stored there.
archive_path :: proc(tree: ^Tree, archive: u16, allocator := context.allocator) -> (path: string, in_dir: bool) {
	if archive == ARCHIVE_IN_DIR {
		return strings.clone(tree.dir_path, allocator), true
	}
	stem := filepath.stem(tree.dir_path)
	if strings.has_suffix(stem, "_dir") {
		stem = stem[:len(stem) - 4]
	}
	directory := filepath.dir(tree.dir_path)
	if len(directory) > 0 {
		return fmt.aprintf("%s/%s_%03d.vpk", directory, stem, archive, allocator = allocator), false
	}
	return fmt.aprintf("%s_%03d.vpk", stem, archive, allocator = allocator), false
}

// data reads one entry and checks the CRC the tree records for it.
read_entry :: proc(tree: ^Tree, entry: Entry, allocator := context.allocator) -> (payload: []u8, ok: bool, d: diag.Diagnostics) {
	d = diag.init()
	path, in_dir := archive_path(tree, entry.archive, allocator)
	defer delete(path)
	offset := i64(entry.offset)
	if in_dir {
		// An entry stored inside the directory file is addressed from the end of
		// the tree, not from the start of the file.
		offset += i64(HEADER_BYTES) + i64(tree.tree_size)
	}
	handle, open_err := os.open(path)
	if open_err != nil {
		diag.err(&d, "vpk.archive", fmt.aprintf("%s could not be opened", path))
		return
	}
	defer os.close(handle)
	if _, seek_err := os.seek(handle, offset, .Start); seek_err != nil {
		diag.err(&d, "vpk.seek", fmt.aprintf("%s could not be seeked", path))
		return
	}
	buffer := make([]u8, entry.length, allocator)
	read, read_err := os.read(handle, buffer)
	if read_err != nil || read != int(entry.length) {
		diag.err(&d, "vpk.short-entry", fmt.aprintf("entry %s/%s.%s is shorter than declared", entry.dir, entry.name, entry.ext))
		delete(buffer)
		return
	}
	if entry.preload > 0 {
		// Preloaded bytes live in the tree, before the record's payload, and this
		// reader does not splice them: the corpus has none.
		diag.warn(&d, "vpk.preload", "an entry carries preloaded bytes")
	}
	if hash.crc32(buffer) != entry.crc {
		diag.err(&d, "vpk.crc", fmt.aprintf("entry %s/%s.%s fails its CRC32", entry.dir, entry.name, entry.ext))
		delete(buffer)
		return
	}
	return buffer, true, d
}
