// Pakfile: the ZIP archive embedded in a Source BSP (lump 40).
//
// Everything the map packs for itself lives here: VTF textures, VMT materials,
// sounds and particle scripts. The central directory is parsed first, then each
// entry is read from its local header; stored and deflated entries are supported.
package bsp

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:strings"
import "../diag"

// LUMP_PAKFILE is the embedded ZIP archive.
LUMP_PAKFILE :: 40

Pak_Entry :: struct {
	name:        string,
	method:      u16,
	comp_size:   int,
	uncomp_size: int,
	data_offset: int, // absolute file offset of the entry payload
}

pak_u16 :: proc(data: []u8, at: int) -> u16 {
	return u16(data[at]) | u16(data[at + 1]) << 8
}

pak_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24
}

// read_pakfile parses the central directory. It returns an empty list when the
// lump is absent or is not a ZIP archive.
read_pakfile :: proc(data: []u8, offset, length: int, allocator := context.allocator) -> (entries: []Pak_Entry, d: diag.Diagnostics) {
	d = diag.init()
	if length <= 0 || offset <= 0 || offset + length > len(data) {
		return
	}
	// The end-of-central-directory record is in the last 64 KiB (no comment in
	// practice); scan backwards for its signature.
	end := offset + length
	start := max(offset, end - 65_557)
	eocd := -1
	for at := end - 22; at >= start; at -= 1 {
		if pak_u32(data, at) == 0x06054b50 {
			eocd = at
			break
		}
	}
	if eocd < 0 {
		diag.warn(&d, "bsp.pakfile-not-zip", "pakfile lump has no ZIP end record")
		return
	}
	count := int(pak_u16(data, eocd + 10))
	dir_offset := offset + int(pak_u32(data, eocd + 16))
	if count <= 0 || count > 100_000 || dir_offset <= 0 || dir_offset >= end {
		diag.warn(&d, "bsp.pakfile-bad-directory", fmt.aprintf("implausible ZIP directory (%d entries)", count))
		return
	}
	entries = make([]Pak_Entry, count, allocator)
	at := dir_offset
	written := 0
	for _ in 0..<count {
		if at + 46 > end || pak_u32(data, at) != 0x02014b50 {
			break
		}
		method := pak_u16(data, at + 10)
		comp_size := int(pak_u32(data, at + 20))
		uncomp_size := int(pak_u32(data, at + 24))
		name_len := int(pak_u16(data, at + 28))
		extra_len := int(pak_u16(data, at + 30))
		comment_len := int(pak_u16(data, at + 32))
		local := offset + int(pak_u32(data, at + 42))
		name := string(data[at + 46:at + 46 + name_len])
		if local + 30 > end || pak_u32(data, local) != 0x04034b50 {
			break
		}
		name_len_local := int(pak_u16(data, local + 26))
		extra_len_local := int(pak_u16(data, local + 28))
		data_offset := local + 30 + name_len_local + extra_len_local
		if data_offset + comp_size > end {
			break
		}
		entries[written] = Pak_Entry {
			name        = strings.clone(name, allocator),
			method      = method,
			comp_size   = comp_size,
			uncomp_size = uncomp_size,
			data_offset = data_offset,
		}
		written += 1
		at += 46 + name_len + extra_len + comment_len
	}
	entries = entries[:written]
	return
}

// pak_entry_data decodes one entry. Stored entries are sliced; deflated ones are
// inflated into a fresh buffer.
pak_entry_data :: proc(data: []u8, entry: Pak_Entry, allocator := context.allocator) -> (out: []u8, ok: bool) {
	raw := data[entry.data_offset:entry.data_offset + entry.comp_size]
	switch entry.method {
	case 0:
		return raw, true
	case 8:
		buffer: bytes.Buffer
		bytes.buffer_init_allocator(&buffer, 0, entry.uncomp_size, allocator)
		err := zlib.inflate(input = raw, buf = &buffer, expected_output_size = entry.uncomp_size, raw = true)
		if err != nil {
			return nil, false
		}
		return buffer.buf[:], true
	}
	return nil, false
}
