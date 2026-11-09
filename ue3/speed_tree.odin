package ue3

import "core:fmt"
import "../diag"

// USpeedTree::Serialize (Engine/Src/SpeedTree.cpp:1028): when the build does
// not keep the SpeedTree 5 supporting data (or the asset is legacy), the body
// is a declared length followed by exactly that many opaque bytes. Measured on
// the corpus: first INT + 4 == body size in every sampled export, and the blob
// starts with the SpeedTree SDK header, so the envelope is interpreted and the
// licensed payload is skipped.
Speed_Tree :: struct {
	payload: i32,
}

read_speed_tree :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Speed_Tree, d: diag.Diagnostics) {
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
	bytes := read_i32(&r)
	if r.failed || bytes < 0 || int(bytes) != r.limit - r.pos {
		diag.err(&d, "ue3.bad-speedtree", fmt.aprintf("declared size %d does not match %d remaining bytes", bytes, r.limit - r.pos))
		return
	}
	r.pos = r.limit
	result.payload = bytes
	return
}
