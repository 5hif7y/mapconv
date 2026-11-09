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
Brush_Component :: struct {
	convex_sets: int,
	elements:    int,
	payload:     i64,
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
	result.convex_sets, result.elements, result.payload, ok = walk_cached_convex_sets(&r, &d, "brush")
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
			r.pos += int(count)
			elements_out += 1
			payload_out += i64(count)
		}
	}
	ok = true
	return
}
