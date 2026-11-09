package ue3

import "core:fmt"
import "../diag"

// UDecalComponent (Engine/Src/DecalComponent.cpp) for 576: NumStaticReceivers,
// then one FStaticReceiverData per receiver (Engine/Src/DecalRenderData.cpp):
// Component reference, vertex bulk, index bulk, NumTriangles and the LightMap1D
// reference. The light map is the same reference form as the components:
// a DWORD kind followed by the 1D/2D payload, so the shared walker is used.
// ShadowMap1D, Data and InstanceIndex are gated at 666/621/665, i.e. absent.
Decal_Component :: struct {
	receivers:  int,
	vertices:   int,
	triangles:  int,
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
		d = head_d
		return
	}
	defer delete(head_d.items)
	version := engine_version(&pkg.summary)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	n := read_i32(&r)
	if r.failed || n < 0 || n > 100_000 {
		diag.err(&d, "ue3.bad-decal", fmt.aprintf("implausible receiver count %d", n))
		return
	}
	result.receivers = int(n)
	for _ in 0 ..< int(n) {
		_ = read_i32(&r) // Component
		stride := read_i32(&r)
		count := read_i32(&r)
		if r.failed || stride <= 0 || stride > 512 || count < 0 || count > 5_000_000 {
			diag.err(&d, "ue3.bad-decal", "implausible vertex bulk")
			return
		}
		if i64(stride) * i64(count) > i64(r.limit - r.pos) {
			diag.err(&d, "ue3.bad-decal", "vertex bulk overruns the export")
			return
		}
		r.pos += int(stride) * int(count)
		result.vertices += int(count)
		istride := read_i32(&r)
		icount := read_i32(&r)
		if r.failed || istride != 2 || icount < 0 || icount > 20_000_000 {
			diag.err(&d, "ue3.bad-decal", "implausible index bulk")
			return
		}
		if i64(icount) * 2 > i64(r.limit - r.pos) {
			diag.err(&d, "ue3.bad-decal", "index bulk overruns the export")
			return
		}
		r.pos += int(icount) * 2
		triangles := read_i32(&r)
		if r.failed || triangles < 0 {
			diag.err(&d, "ue3.bad-decal", "implausible triangle count")
			return
		}
		result.triangles += int(triangles)
		if !skip_lightmap_ref(&r, version) {
			diag.err(&d, "ue3.bad-decal", "light map did not parse")
			return
		}
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.decal-layout", fmt.aprintf("UDecalComponent consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
