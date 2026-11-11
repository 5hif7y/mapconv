package ue3

import "core:fmt"
import "../diag"

// USoundNodeWave (Engine/Src/UnAudioNodes.cpp) carries its payload in
// FBulkData members: RawData, CompressedPCData, CompressedXbox360Data,
// CompressedPS3Data and, behind version gates, the WiiU/iPhone/Flash variants.
// The presence of the gated members depends on the build, so the reader tries
// bulk counts 1..6 in both field orders (count,size,offset) and
// (count,offset,size) and accepts only the combination that ends exactly at
// the end of the export. Data stored inline (offset == 0) is skipped; data in a
// separate file (offset != 0) is already outside the payload.
Sound_Node_Wave :: struct {
	bulks: int,
}

read_sound_node_wave :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Sound_Node_Wave, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller: deleting them here and
		// again in the caller is a double free that kills the process.
		d = head_d
		return
	}
	defer delete(head_d.items)
	start := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	for count in 1 ..= 6 {
		r := start
		ok := true
		for _ in 0 ..< count {
			if r.pos + 16 > head.end_offset {
				ok = false
				break
			}
			_ = read_u32(&r)
			elements := read_i32(&r)
			size := read_i32(&r)
			offset := read_i32(&r)
			if r.failed || elements < 0 || size < 0 || offset < 0 {
				ok = false
				break
			}
			// Sound bulks are byte arrays: element count equals byte count.
			// The payload is stored inline right after the header; the offset
			// field only records where it landed in the cooked file.
			if elements != size {
				ok = false
				break
			}
			if int(size) > head.end_offset - r.pos {
				ok = false
				break
			}
			// A cooked PC sound is a Vorbis stream, and every inline payload in the
			// corpus starts with its page header. That is what makes the bulk table a
			// reading of the bytes instead of a fit: a wrong element count shifts the
			// next header and the magic stops matching.
			if size > 4 && string(pkg.data[r.pos:r.pos + 4]) != "OggS" {
				ok = false
				break
			}
			r.pos += int(size)
		}
		if ok && r.pos == head.end_offset {
			result.bulks = count
			return
		}
	}
	diag.err(&d, "ue3.sound-layout", "USoundNodeWave did not consume the export")
	return
}
