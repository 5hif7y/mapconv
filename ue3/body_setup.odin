package ue3

import "core:fmt"
import "../diag"

// URB_BodySetup (Engine/Src/UnPhysAsset.cpp:591) writes only
// PreCachedPhysData: TArray<FKCachedConvexData> (Engine/Inc/UnPhysPublic.h:677),
// each one a TArray<FKCachedConvexDataElement> whose ConvexElementData is a byte
// bulk. The cooked shape is the same one UBrushComponent uses, so the walker is
// shared; the PhysX blob inside each element stays opaque.
Body_Setup :: struct {
	convex_sets: int,
	elements:    int,
	payload:     i64,
}

read_body_setup :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Body_Setup, d: diag.Diagnostics) {
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
	result.convex_sets, result.elements, result.payload, ok = walk_cached_convex_sets(&r, &d, "body setup")
	if !ok {
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.body-setup-layout", fmt.aprintf("URB_BodySetup consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
