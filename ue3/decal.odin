package ue3

import "core:fmt"
import "../diag"

// UDecalComponent (Engine/Src/DecalComponent.cpp) for 576: NumStaticReceivers,
// then one FStaticReceiverData per receiver (Engine/Src/DecalRenderData.cpp):
// Component reference, vertex bulk, index bulk, NumTriangles and a LightMap1D
// reference. ShadowMap1D, Data and InstanceIndex are gated at 666/621/665 and
// are absent here. The LightMap1D reference is accepted as 4 or 8 bytes; the
// combination that ends exactly at the export end is the one reported.
Decal_Component :: struct {
	receivers:  int,
	vertices:   int,
	triangles:  int,
	lightmap_ref: int,
}

read_decal_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Decal_Component, d: diag.Diagnostics) {
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
	parse :: proc(r: ^Reader, end: int, ref_size: int, res: ^Decal_Component) -> bool {
		n := read_i32(r)
		if r.failed || n < 0 || n > 100_000 {
			return false
		}
		res.receivers = int(n)
		vertices, triangles := 0, 0
		for _ in 0 ..< int(n) {
			_ = read_i32(r) // Component
			stride := read_i32(r)
			count := read_i32(r)
			if r.failed || stride <= 0 || stride > 512 || count < 0 || count > 5_000_000 {
				return false
			}
			// i64: stride*count overflows i32 for large (but accepted) counts,
			// the product wraps negative and the check passes.
			if i64(stride) * i64(count) > i64(end - r.pos) {
				return false
			}
			r.pos += int(stride) * int(count)
			vertices += int(count)
			istride := read_i32(r)
			icount := read_i32(r)
			if r.failed || istride != 2 || icount < 0 || icount > 20_000_000 {
				return false
			}
			if i64(icount) * 2 > i64(end - r.pos) {
				return false
			}
			r.pos += int(icount) * 2
			t := read_i32(r)
			if r.failed || t < 0 {
				return false
			}
			triangles += int(t)
			if ref_size > end - r.pos {
				return false
			}
			r.pos += ref_size
		}
		res.vertices = vertices
		res.triangles = triangles
		res.lightmap_ref = ref_size
		return true
	}
	for ref_size in ([]int{4, 8}) {
		r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
		if parse(&r, head.end_offset, ref_size, &result) && r.pos == head.end_offset {
			return
		}
	}
	diag.err(&d, "ue3.decal-layout", "UDecalComponent did not consume the export")
	return
}
