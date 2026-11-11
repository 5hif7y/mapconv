package ue3

import "core:fmt"
import "../diag"

// UBrushComponent (Engine/Src/UnBrushComponent.cpp:471) writes only
// CachedPhysBrushData: TArray<FKCachedConvexData>, each one a
// TArray<FKCachedConvexDataElement> whose ConvexElementData is a byte bulk.
//
// Measured layout (17 of 17 components in arena01, every body ends exactly):
// set count, per set an element count, then per element a byte count followed
// by that many bytes. The element-size word that Array.h writes is not present
// in this build's cooked form, so the reader follows the measurement; the
// payload is a PhysX blob ("NXS" magic) and is skipped, not decoded.
// Every convex element is a cache of a PhysX cooked mesh, and a cooked mesh always
// opens as a Nexus stream: twelve bytes of quick-load header, then "NXS" and the
// format version. The header is the one cross-check the payload offers without
// decoding PhysX, and it is enough to notice a walk that drifts into the middle of
// an element.
PHYSX_STREAM_MAGIC :: "NXS\x01"
// PhysX writes four sections into a cooked convex mesh (hull, big hull, gauss map,
// mass properties) and the quick-load header counts them.
PHYSX_CHUNKS :: 4

Brush_Component :: struct {
	convex_sets: int,
	elements:    int,
	payload:     i64,
	// Measured, not enforced: the quick-load header holds a size, a zero and a chunk
	// count. The chunk count is 4 in every element of the corpus; keeping it as a
	// counter says so without inventing a rule from three samples.
	chunk_counts: map[i32]int,
	header_sizes: i64,
}

read_brush_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Brush_Component, d: diag.Diagnostics) {
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
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	ok: bool
	result.chunk_counts = make(map[i32]int, 4, allocator)
	result.convex_sets, result.elements, result.payload, ok = walk_cached_convex_sets(&r, &d, "brush", &result.chunk_counts, &result.header_sizes)
	if !ok {
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.brush-layout", fmt.aprintf("UBrushComponent consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}

// walk_cached_convex_sets consumes a TArray<FKCachedConvexData> as this build
// cooks it: a set count, per set an element count, then per element a byte count
// followed by that many bytes. Both UBrushComponent.CachedPhysBrushData and
// URB_BodySetup.PreCachedPhysData use it; the payload is a PhysX blob and is
// skipped, not decoded.
walk_cached_convex_sets :: proc(
	r: ^Reader,
	d: ^diag.Diagnostics,
	what: string,
	chunk_counts: ^map[i32]int = nil,
	header_sizes: ^i64 = nil,
) -> (sets_out: int, elements_out: int, payload_out: i64, ok: bool) {
	sets := read_i32(r)
	if r.failed || sets < 0 || sets > 64 {
		diag.err(d, "ue3.bad-cached-phys", fmt.aprintf("%s: implausible convex set count %d", what, sets))
		return
	}
	sets_out = int(sets)
	for _ in 0 ..< int(sets) {
		elements := read_i32(r)
		if r.failed || elements < 0 || elements > 100_000 {
			diag.err(d, "ue3.bad-cached-phys", fmt.aprintf("%s: implausible convex element count", what))
			return
		}
		for _ in 0 ..< int(elements) {
			count := read_i32(r)
			if r.failed || count < 0 || count > 50_000_000 {
				diag.err(d, "ue3.bad-cached-phys", fmt.aprintf("%s: implausible bulk size", what))
				return
			}
			if i64(count) > i64(r.limit - r.pos) {
				diag.err(d, "ue3.bad-cached-phys", fmt.aprintf("%s: bulk payload overruns the export", what))
				return
			}
			if count < 16 || string(r.data[r.pos + 12:r.pos + 16]) != PHYSX_STREAM_MAGIC {
				diag.err(d, "ue3.physx-magic",
					fmt.aprintf("%s: a convex element of %d bytes does not carry the PhysX stream header", what, count))
				return
			}
			// The quick-load header is {size, zero, chunk count} before the stream. The
			// zero word and the count of four sections held in all 4,234 elements of the
			// corpus, so a different value means the walk is reading a size that is not
			// an element.
			if read_i32_at(r.data, r.pos + 4) != 0 || read_i32_at(r.data, r.pos + 8) != PHYSX_CHUNKS {
				diag.err(d, "ue3.physx-header",
					fmt.aprintf("%s: a convex element of %d bytes has no quick-load header", what, count))
				return
			}
			if chunk_counts != nil {
				chunks := u32(read_i32_at(r.data, r.pos + 8))
				chunk_counts^[i32(chunks)] = chunk_counts^[i32(chunks)] + 1
				header_sizes^ += i64(u32(read_i32_at(r.data, r.pos)))
			}
			r.pos += int(count)
			elements_out += 1
			payload_out += i64(count)
		}
	}
	ok = true
	return
}
