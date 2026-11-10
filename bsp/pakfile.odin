// Pakfile: the ZIP archive embedded in a Source BSP (lump 40).
//
// Everything the map packs for itself lives here: VTF textures, VMT materials,
// sounds and particle scripts. The central directory is parsed first, then each
// entry is read from its local header; stored and deflated entries are supported.
package bsp

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "../diag"

// LUMP_PAKFILE is the embedded ZIP archive.
LUMP_PAKFILE :: 40

Pak_Entry :: struct {
	name:        string,
	method:      u16,
	crc:         u32,
	comp_size:   int,
	uncomp_size: int,
	record:      int, // absolute file offset of the local header
	data_offset: int, // absolute file offset of the entry payload
}

// Pak_Report is the outcome of checking a whole archive rather than parsing it.
// Source writes every entry stored, so the payload CRC32 is the entire
// verification: an entry that matches it is decoded content, not a bounded
// region. The local headers must tile the lump with no gap and no overlap, which
// is the second check that keeps the parser honest.
Pak_Report :: struct {
	entries:  int,
	stored:   int,
	deflated: int,
	payload:  i64, // bytes of entry payload the archive declares
	verified: int, // entries whose CRC32 matched
	reason:   string,
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
	if length <= 0 || offset < 0 || offset + length > len(data) {
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
		crc := pak_u32(data, at + 16)
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
			crc         = crc,
			record      = local,
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

// verify_pakfile checks the archive end to end and reports the first thing that
// does not hold. An empty reason means every entry was decoded, its CRC32 matched
// the directory, its local header agreed with it, and the records tile the lump
// from the first byte to the directory with nothing left over.
verify_pakfile :: proc(data: []u8, offset, length: int) -> (report: Pak_Report) {
	if length <= 0 || offset < 0 || offset + length > len(data) {
		report.reason = "lump is outside the file"
		return
	}
	end := offset + length
	eocd := -1
	start := max(offset, end - 65_557)
	for at := end - 22; at >= start; at -= 1 {
		if pak_u32(data, at) == 0x06054b50 {
			eocd = at
			break
		}
	}
	if eocd < 0 {
		report.reason = "no end of central directory record"
		return
	}
	count := int(pak_u16(data, eocd + 10))
	dir_size := int(pak_u32(data, eocd + 12))
	dir_start := offset + int(pak_u32(data, eocd + 16))
	comment_len := int(pak_u16(data, eocd + 20))
	if eocd + 22 + comment_len != end {
		report.reason = "bytes after the end record"
		return
	}
	if count == 0 {
		if dir_size != 0 || dir_start != eocd {
			report.reason = "empty archive with a directory"
			return
		}
		return
	}
	if dir_start < offset || dir_start + dir_size != eocd {
		report.reason = "directory does not end at the end record"
		return
	}
	entries, d := read_pakfile(data, offset, length)
	defer {
		for entry in entries {
			delete(entry.name)
		}
		delete(entries)
		delete(d.items)
	}
	if len(entries) != count {
		report.reason = fmt.aprintf("directory holds %d of %d entries", len(entries), count)
		return
	}
	report.entries = count
	for entry in entries {
		switch entry.method {
		case 0:
			report.stored += 1
		case 8:
			report.deflated += 1
		case:
			report.reason = fmt.aprintf("entry %.60s uses compression method %d", entry.name, entry.method)
			return
		}
		report.payload += i64(entry.comp_size)
		// The local header has to repeat what the directory says, or the two
		// disagree about what the payload is and neither reading can be trusted.
		local := entry.record
		if local + 30 > end || pak_u32(data, local) != 0x04034b50 {
			report.reason = fmt.aprintf("entry %.60s has no local header", entry.name)
			return
		}
		flags := pak_u16(data, local + 6)
		if flags & 8 != 0 {
			report.reason = fmt.aprintf("entry %.60s streams its sizes in a data descriptor", entry.name)
			return
		}
		local_name_len := int(pak_u16(data, local + 26))
		if local_name_len != len(entry.name) || string(data[local + 30:local + 30 + local_name_len]) != entry.name {
			report.reason = fmt.aprintf("entry %.60s is named differently in its local header", entry.name)
			return
		}
		if pak_u32(data, local + 14) != entry.crc ||
		   int(pak_u32(data, local + 18)) != entry.comp_size ||
		   int(pak_u32(data, local + 22)) != entry.uncomp_size {
			report.reason = fmt.aprintf("entry %.60s has different sizes or CRC than its local header", entry.name)
			return
		}
		raw := data[entry.data_offset:entry.data_offset + entry.comp_size]
		switch entry.method {
		case 0:
			if hash.crc32(raw) != entry.crc {
				report.reason = fmt.aprintf("entry %.60s fails its CRC32", entry.name)
				return
			}
		case 8:
			buffer: bytes.Buffer
			bytes.buffer_init_allocator(&buffer, 0, entry.uncomp_size, context.allocator)
			defer bytes.buffer_destroy(&buffer)
			err := zlib.inflate(input = raw, buf = &buffer, expected_output_size = entry.uncomp_size, raw = true)
			if err != nil || len(buffer.buf) != entry.uncomp_size {
				report.reason = fmt.aprintf("entry %.60s does not inflate to its declared size", entry.name)
				return
			}
			if hash.crc32(buffer.buf[:]) != entry.crc {
				report.reason = fmt.aprintf("entry %.60s fails its CRC32", entry.name)
				return
			}
		}
		report.verified += 1
	}
	// The records must tile the lump: the first at its start, each one where the
	// previous ended, and the last where the directory begins.
	order := make([]Pak_Entry, len(entries), context.allocator)
	defer delete(order)
	copy(order, entries)
	slice.sort_by(order, proc(a, b: Pak_Entry) -> bool { return a.record < b.record })
	if order[0].record != offset {
		report.reason = "first record does not start the lump"
		return
	}
	for i in 1..<len(order) {
		previous := order[i-1].data_offset + order[i-1].comp_size
		if previous != order[i].record {
			report.reason = fmt.aprintf("%d bytes between two records", order[i].record - previous)
			return
		}
	}
	last := order[len(order)-1].data_offset + order[len(order)-1].comp_size
	if last != dir_start {
		report.reason = fmt.aprintf("%d bytes between the last record and the directory", dir_start - last)
		return
	}
	return
}
