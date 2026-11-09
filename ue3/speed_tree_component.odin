package ue3

import "core:fmt"
import "../diag"

// USpeedTreeComponent::Serialize (Engine/Src/SpeedTreeComponent.cpp:1567) only
// writes the static lighting: five light map references after the
// VER_SPEEDTREE_5_INTEGRATION gate (643) and four before it. The shared
// light map reference walker lives in model_component.odin.
Speed_Tree_Component :: struct {
	lightmaps: int,
}

read_speed_tree_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Speed_Tree_Component, d: diag.Diagnostics) {
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
	version := engine_version(&pkg.summary)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	count := 4
	if version >= 643 {
		count = 5
	}
	for _ in 0 ..< count {
		if !skip_lightmap_ref(&r, version) {
			diag.err(&d, "ue3.bad-speedtree", "light map did not parse")
			return
		}
		result.lightmaps += 1
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.speedtree-layout", fmt.aprintf("USpeedTreeComponent consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
