// UFracturedStaticMesh: a static mesh followed by its fracture data.
//
// UnFracturedStaticMesh.cpp:132 calls Super::Serialize (the whole UStaticMesh
// payload), then writes:
//
//	SourceStaticMesh      object reference
//	Fragments             count and one FFracturedMeshFragment per entry
//	CoreFragmentIndex     -1 when there is no core fragment
//	InteriorElementIndex  from VER_FRAGMENT_INTERIOR_INDEX
//	CoreMeshScale3D, CoreMeshOffset, CoreMeshRotation, PlaneBias
//	NonCriticalBuildVersion, LicenseeNonCriticalBuildVersion
//
// The fragment records are not described anywhere in the tree (FFracturedMeshFragment
// is absent), so the reader anchors from the tail instead: it walks the static
// mesh part, reads the fragment count, validates the sixty byte tail (core and
// interior indices, the four vectors, the two build words) and requires the
// fragment region to end exactly where that tail starts. The fragment contents
// stay opaque; only their envelope is credited.
package ue3

import "core:fmt"
import "core:math"
import "../diag"

FRACTURED_TAIL_BYTES :: 60

Fractured_Mesh :: struct {
	export_index:  int,
	fragments:     int,
	fragment_data: int,
	core_index:    i32,
	interior_index: i32,
	build_version: u16,
}

read_fractured_static_mesh :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (mesh: Fractured_Mesh, d: diag.Diagnostics) {
	d = diag.init()
	mesh.export_index = export_index
	base, base_d := read_static_mesh(pkg, export_index, allocator)
	if diag.has_errors(&base_d) {
		for item in base_d.items {
			diag.add(&d, item.severity, item.code, item.message, item.object, item.loc)
		}
		return
	}
	for lod in base.lods {
		delete(lod.positions)
		delete(lod.uvs)
		delete(lod.indices)
		delete(lod.sections)
	}
	delete(base.lods)

	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	defer delete(head_d.items)

	tail_start := head.end_offset - FRACTURED_TAIL_BYTES
	if tail_start < base.body_end + 4 {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("export ends at %d, too short for the fracture tail after the mesh at %d", head.end_offset, base.body_end))
		return
	}
	// The fragment array: count, then the records up to the tail.
	r := Reader{data = pkg.data, pos = base.body_end, limit = tail_start}
	count := read_i32(&r)
	if r.failed || count < 0 || count > 10_000 {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("implausible fragment count %d", count))
		return
	}
	if count > 0 && (tail_start - r.pos) % int(count) != 0 {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("%d fragment bytes do not divide by %d fragments", tail_start - r.pos, count))
		return
	}
	mesh.fragments = int(count)
	mesh.fragment_data = tail_start - r.pos

	// The fixed tail, in the order the serializer writes it.
	t := Reader{data = pkg.data, pos = tail_start, limit = head.end_offset}
	mesh.core_index = read_i32(&t)
	mesh.interior_index = read_i32(&t)
	for _ in 0 ..< 12 {
		value := read_f32(&t)
		if !(value == value) || math.abs(value) > 1e12 {
			diag.err(&d, "ue3.bad-fractured", "the fracture vectors are not finite")
			return
		}
	}
	mesh.build_version = read_u16(&t)
	licensee := read_u16(&t)
	if t.failed || mesh.build_version == 0 || licensee == 0 {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("implausible fracture build words %d and %d", mesh.build_version, licensee))
		return
	}
	if t.pos != head.end_offset {
		diag.err(&d, "ue3.bad-fractured", "the fracture tail did not end with the export")
		return
	}
	return
}
