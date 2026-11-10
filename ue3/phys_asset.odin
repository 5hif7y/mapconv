// URB_BodySetup carries the cooked collision geometry of a rigid body.
//
// URB_BodySetup::Serialize (Engine/Src/UnPhysAsset.cpp:591) is Super::Serialize
// followed by `Ar << PreCachedPhysData`, a TArrayNoInit<FKCachedConvexData>
// (Engine/Inc/EnginePhysicsClasses.h:984). Each FKCachedConvexData is a
// TArray<FKCachedConvexDataElement> and each element writes its
// ConvexElementData with TArray<BYTE>::BulkSerialize (Engine/Inc/UnPhysPublic.h:669),
// so the payload is a counted array of counted byte blobs whose content is a PhysX
// cooked stream.
//
// The bytes of this build frame those blobs one level further than the header says,
// and the framing is what this reader checks:
//
//   u32 group count
//   u32 records in the first group
//   group count x (that many record) with a u32 record count before every group
//   record: u32 one, u32 size, u32 secondary, u32 zero, u32 id length, id bytes,
//           then size - 16 bytes of cooked data
//
// The identifiers are four bytes ending in 0x01 ("NXS\x01" in every record of the
// corpus). A record is accepted only if its leading one, its zero word and its
// identifier length hold, and the walk has to land exactly on the end of the
// export; that combination is what keeps a wrong size from passing.
package ue3

import "core:fmt"
import "../diag"

Precached_Blob :: struct {
	size:       i32,
	identifier: [4]u8,
	offset:     int,
}

Precached_Data :: struct {
	blobs:      []Precached_Blob,
	end_offset: int,
}

read_precached_phys_data :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Precached_Data, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	head, head_d := read_object_head(pkg, pkg.exports[export_index], allocator, export_index)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	delete(head_d.items)
	end := head.end_offset
	r := Reader{data = pkg.data, pos = head.body_offset, limit = end}

	groups := int(read_i32(&r))
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if groups == 0 {
		if r.pos != end {
			diag.err(&d, "ue3.bad-precached", "an empty cache still has trailing bytes")
			return
		}
		result.end_offset = r.pos
		return
	}
	if groups < 0 || groups > 4096 {
		diag.err(&d, "ue3.bad-precached", fmt.aprintf("implausible group count %d", groups))
		return
	}
	blobs := make([dynamic]Precached_Blob, 0, 64, allocator)
	per_group := int(read_i32(&r))
	for group in 0 ..< groups {
		if r.failed || per_group < 0 || per_group > 4096 {
			diag.err(&d, "ue3.bad-precached", fmt.aprintf("implausible record count %d", per_group))
			return
		}
		for _ in 0 ..< per_group {
			if !need(&r, 24) {
				diag.err(&d, "ue3.bad-precached", "a record header overruns the export")
				return
			}
			one := read_i32(&r)
			size := read_i32(&r)
			_ = read_i32(&r) // secondary size, not needed to walk
			zero := read_i32(&r)
			id_length := read_i32(&r)
			if r.failed {
				diag.err(&d, "ue3.truncated", r.message)
				return
			}
			if one != 1 || zero != 0 || id_length != 4 {
				diag.err(
					&d,
					"ue3.bad-precached-record",
					fmt.aprintf("record opens with %d, %d and identifier length %d", one, zero, id_length),
				)
				return
			}
			identifier: [4]u8
			for i in 0 ..< 4 {
				identifier[i] = read_u8(&r)
			}
			// The identifiers are three printable bytes and a version byte.
			for i in 0 ..< 3 {
				if identifier[i] < 0x20 || identifier[i] >= 0x7f {
					diag.err(&d, "ue3.bad-precached-record", "a cooked stream identifier is not printable")
					return
				}
			}
			payload := int(size) - 16
			if payload < 0 || !need(&r, payload) {
				diag.err(&d, "ue3.bad-precached-record", fmt.aprintf("a record declares %d bytes", size))
				return
			}
			append(&blobs, Precached_Blob{size = size, identifier = identifier, offset = r.pos})
			r.pos += payload
		}
		if group + 1 < groups {
			per_group = int(read_i32(&r))
			if r.failed {
				diag.err(&d, "ue3.truncated", r.message)
				return
			}
		}
	}
	if r.pos != end {
		diag.err(
			&d,
			"ue3.precached-end-mismatch",
			fmt.aprintf("the cached data ends at %d but the export ends at %d", r.pos, end),
		)
		return
	}
	result.blobs = blobs[:]
	result.end_offset = r.pos
	return
}

precached_data_destroy :: proc(data: ^Precached_Data) {
	delete(data.blobs)
	data.blobs = nil
}
