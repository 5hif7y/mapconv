// UFracturedStaticMesh: a static mesh followed by its fracture data.
//
// UnFracturedStaticMesh.cpp:125 calls Super::Serialize (the whole UStaticMesh payload),
// then writes:
//
//	SourceStaticMesh      object reference
//	Fragments             count and one FFragmentInfo per entry
//	CoreFragmentIndex     -1 when there is no core fragment
//	InteriorElementIndex  from VER_FRAGMENT_INTERIOR_INDEX
//	CoreMeshScale3D, CoreMeshOffset, CoreMeshRotation, PlaneBias
//	NonCriticalBuildVersion, LicenseeNonCriticalBuildVersion
//
// The fragment record was the part this reader did not have, and it was written off as
// unmeasurable because the corpus holds two meshes with one fragment each. It is in the
// source tree, in UnFracturedStaticMesh.h:22 (`FFragmentInfo`) and UnPhysPublic.h:643
// (`FKConvexElem`), and it is fully described there:
//
//	Center                    FVector                                    12
//	ConvexHull.VertexData     TArray<FVector>      count, then 12 each
//	ConvexHull.PermutedVertexData TArray<FPlane>   count, then 16 each
//	ConvexHull.FaceTriData    TArray<i32>          count, then  4 each
//	ConvexHull.EdgeDirections TArray<FVector>      count, then 12 each
//	ConvexHull.FaceNormalDirections TArray<FVector> count, then 12 each
//	ConvexHull.FacePlaneData  TArray<FPlane>       count, then 16 each
//	ConvexHull.ElemBox        FBox                                                        24
//	Bounds                    FBoxSphereBounds: origin, extent, radius                    28
//	Neighbours                TArray<u8>           count, then  1 each
//	bCanBeDestroyed, bRootFragment, bNeverSpawnPhysicsChunk    three UBOOL, 4 each       12
//	AverageExteriorNormal     FVector                                    12
//	NeighbourDims             TArray<f32>          count, then  4 each
//
// The record is variable length, and the source states the invariant that makes it
// checkable: `Neighbours` "corresponds to planes in ConvexHull.FacePlaneData, and needs to
// match its size", and `NeighbourDims` "also needs to be same size as Neighbours and
// ConvexHull.FacePlaneData" (UnFracturedStaticMesh.h:30-33). Three counts from three
// different arrays have to agree, and a neighbour either names another fragment or is 255
// ("exterior face or invalid neighbour", :30).
//
// What is checked here, per fragment and per mesh:
//
//	counts agree:   Neighbours == FacePlaneData == NeighbourDims
//	hull is one:    VertexData == PermutedVertexData, FacePlaneData >= 4 (a closed hull)
//	triangles:      FaceTriData is a multiple of three and every index is a vertex
//	neighbours:     every byte is 255 or an index of a fragment that exists
//	boxes:          ElemBox is ordered and finite, the centre and the bounds origin sit
//	                inside the extended box, the bounds radius is not negative
//	envelope:       the last fragment ends exactly where the tail begins, and the tail
//	                ends exactly where the export ends
package ue3

import "core:fmt"
import "core:math"
import "../diag"

// FRACTURED_TAIL_BYTES is the fixed part after the fragments: core index, interior index,
// three vectors (scale, offset, rotation), the plane bias, and the two build words.
FRACTURED_TAIL_BYTES :: 60

// FRACTURED_HEAD_SKIP is what the static mesh serializer writes after the part this
// reader follows, up to the fragment count: measured, not assumed. In both fractured
// meshes of the corpus the count sits 32 bytes past the end of the static mesh part, and
// the 32 bytes hold a word that is 1, six zeros and the word 451 -- constant in both
// objects, so it belongs to the static mesh payload (a version, a flag and a count that
// the mesh reader does not model) and not to the fracture data. A reader that started at
// the static mesh end would read the word 1 as the fragment count and walk 1,250 bytes
// of hull as if it were ten.
FRACTURED_HEAD_SKIP :: 32

// MAX_FRAGMENTS bounds the count a reader will follow: a ship map holds tens, not millions.
MAX_FRAGMENTS :: 4096

// FRAGMENT_MAX_ARRAY bounds the count of each array inside a fragment. A tile of a broken
// mesh has a hull of hundreds of vertices, not of millions.
FRAGMENT_MAX_ARRAY :: 1 << 20

// FRAGMENT_BLOCK_BYTE is the value of the one byte the record carries between the hull box
// and the bounds. It is 1 in all 102 fragments of the corpus.
FRAGMENT_BLOCK_BYTE :: 1

// FRAGMENT_EXTERIOR is the neighbour value that names no fragment.
FRAGMENT_EXTERIOR :: 255

Fractured_Fragment :: struct {
	center:     [3]f32,
	vertices:   int, // VertexData: the hull
	permuted:   int, // PermutedVertexData: the same vertices in SIMD order
	faces:      int, // FacePlaneData: the planes of the hull
	triangles:  int, // FaceTriData / 3
	edges:      int,
	normals:    int,
	neighbours: int,
	dims:       int,
	// exterior counts the faces of this fragment that border nothing: the hull is open
	// there, which is what a piece cut out of a larger mesh looks like.
	exterior: int,
}

Fractured_Mesh :: struct {
	export_index:   int,
	fragments:      int,
	fragment_data:  int,
	core_index:     i32,
	interior_index: i32,
	build_version:  u16,
	// The decoded record, kept so a caller can report what the payload holds instead of
	// only how many bytes it consumed.
	records:        []Fractured_Fragment,
	vertices:       int,
	triangles:      int,
	planes:         int,
	exterior_faces: int,
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

	// `Ar << SourceStaticMesh` is the one field of this serializer that does not reach the
	// file: in this corpus the fragment count sits at the byte where the static mesh part
	// ends, and the envelope closes exactly when it is read from there. So the reference is
	// measured to be empty rather than assumed to be a word -- a reader that skipped four
	// bytes here would be reading the count from the middle of something else.

	r := Reader{data = pkg.data, pos = base.body_end + FRACTURED_HEAD_SKIP, limit = tail_start}
	count := read_i32(&r)
	if r.failed || count <= 0 || count > MAX_FRAGMENTS {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("implausible fragment count %d", count))
		return
	}
	mesh.fragments = int(count)
	mesh.records = make([]Fractured_Fragment, int(count), allocator)

	for index in 0 ..< int(count) {
		fragment, fragment_d := read_fragment(&r, int(count))
		if diag.has_errors(&fragment_d) {
			for item in fragment_d.items {
				diag.add(&d, item.severity, item.code,
					fmt.aprintf("fragment %d: %s", index, item.message), item.object, item.loc)
			}
			delete(fragment_d.items)
			return
		}
		delete(fragment_d.items)
		mesh.records[index] = fragment
		mesh.vertices += fragment.vertices
		mesh.triangles += fragment.triangles
		mesh.planes += fragment.faces
		mesh.exterior_faces += fragment.exterior
	}

	// The envelope: the records have to end where the tail begins. This is the check the
	// old reader could make and the reason the layout is now provable rather than
	// asserted -- a record read at the wrong stride lands short or long here.
	if r.pos != tail_start {
		diag.err(&d, "ue3.bad-fractured",
			fmt.aprintf("the fragments end at %d, %d bytes before the tail at %d", r.pos, tail_start - r.pos, tail_start))
		return
	}
	mesh.fragment_data = tail_start - (base.body_end + FRACTURED_HEAD_SKIP)

	// The fixed tail, in the order the serializer writes it.
	t := Reader{data = pkg.data, pos = tail_start, limit = head.end_offset}
	mesh.core_index = read_i32(&t)
	mesh.interior_index = read_i32(&t)
	// CoreFragmentIndex is an index into the fragment array (or -1 for none), and the
	// interior element index is an element of the mesh (or -1).
	if mesh.core_index < -1 || (mesh.core_index >= 0 && int(mesh.core_index) >= mesh.fragments) {
		diag.err(&d, "ue3.bad-fractured",
			fmt.aprintf("core fragment %d is not one of the %d fragments", mesh.core_index, mesh.fragments))
		return
	}
	if mesh.interior_index < -1 {
		diag.err(&d, "ue3.bad-fractured", fmt.aprintf("interior element index %d is negative", mesh.interior_index))
		return
	}
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

fractured_destroy :: proc(mesh: ^Fractured_Mesh) {
	delete(mesh.records)
	mesh.records = nil
}

// read_fragment walks one FFragmentInfo. `total` is the number of fragments the mesh has,
// which is what a neighbour byte is checked against.
read_fragment :: proc(r: ^Reader, total: int) -> (fragment: Fractured_Fragment, d: diag.Diagnostics) {
	d = diag.init()
	for axis in 0 ..< 3 {
		fragment.center[axis] = read_f32(r)
	}
	if r.failed {
		diag.err(&d, "ue3.bad-fragment", "the fragment ends inside its centre")
		return
	}

	// ConvexHull. Six arrays, each a count and then its records -- they are interleaved in
	// the file, so each count has to be followed by its own data before the next one is
	// read. Only the triangle indices and the planes are looked at; the others are walked
	// and skipped, because knowing their size is what makes the record length exact.
	vertices, vertices_ok := read_count(r, 12)
	permuted, permuted_ok := read_count(r, 16)
	if !vertices_ok || !permuted_ok {
		diag.err(&d, "ue3.bad-fragment", "the convex hull vertex arrays do not fit the payload")
		return
	}
	fragment.vertices = vertices
	fragment.permuted = permuted
	if vertices <= 0 {
		diag.err(&d, "ue3.bad-fragment", "a fragment has no hull vertices")
		return
	}
	// PermutedVertexData holds the vertices in the order the physics engine wants them:
	// four vertices per group of three planes, plus three planes for a remainder of one to
	// three (UnPhysCollision.cpp:2777, `PermuteVertexData`: `(Num/4)*3` groups and
	// `NumRemaining ? 3 : 0` planes). So the two counts are related by a formula, not by
	// equality -- 14 vertices give 12 planes and 16 give 12 as well, which is exactly what
	// the two meshes of the corpus hold, and what a reader that demanded equality rejected.
	expected_permuted := (vertices / 4) * 3
	if vertices % 4 != 0 {
		expected_permuted += 3
	}
	if permuted != expected_permuted {
		diag.err(&d, "ue3.bad-fragment",
			fmt.aprintf("%d permuted planes for %d hull vertices, expected %d",
				permuted, vertices, expected_permuted))
		return
	}

	triangles, triangles_ok := read_count(r, 0)
	if !triangles_ok {
		diag.err(&d, "ue3.bad-fragment", "the hull triangle count does not fit the payload")
		return
	}
	if triangles % 3 != 0 {
		diag.err(&d, "ue3.bad-fragment", fmt.aprintf("%d face indices are not whole triangles", triangles))
		return
	}
	fragment.triangles = triangles / 3
	for k in 0 ..< triangles {
		index := int(read_i32(r))
		if r.failed || index < 0 || index >= vertices {
			diag.err(&d, "ue3.bad-fragment",
				fmt.aprintf("face index %d names vertex %d of %d", k, index, vertices))
			return
		}
	}

	edges, edges_ok := read_count(r, 12)
	normals, normals_ok := read_count(r, 12)
	planes, planes_ok := read_count(r, 16)
	if !edges_ok || !normals_ok || !planes_ok {
		diag.err(&d, "ue3.bad-fragment", "the convex hull direction arrays do not fit the payload")
		return
	}
	fragment.edges = edges
	fragment.normals = normals
	fragment.faces = planes
	// A closed hull has at least four planes; a fragment is a closed piece of a solid.
	if planes < 4 {
		diag.err(&d, "ue3.bad-fragment", fmt.aprintf("a fragment hull has %d planes", planes))
		return
	}

	// The hull ends with its own box: six floats, ordered.
	mins: [3]f32
	maxs: [3]f32
	for axis in 0 ..< 3 {
		mins[axis] = read_f32(r)
	}
	for axis in 0 ..< 3 {
		maxs[axis] = read_f32(r)
	}
	if r.failed {
		diag.err(&d, "ue3.bad-fragment", "the fragment ends inside its hull box")
		return
	}
	for axis in 0 ..< 3 {
		if !(mins[axis] == mins[axis]) || !(maxs[axis] == maxs[axis]) || mins[axis] > maxs[axis] {
			diag.err(&d, "ue3.bad-fragment", "the hull box is not an ordered pair of corners")
			return
		}
	}

	// One byte between the hull box and the bounds: 1 in every fragment of both meshes of
	// the corpus (102 of 102), and the record only closes on the tail when it is read. It
	// is a field of this build that the source tree in the repository does not show --
	// measured, not assumed, and the envelope test is what makes skipping the wrong number
	// of bytes here impossible to hide.
	block_byte := read_u8(r)
	if r.failed || block_byte != FRAGMENT_BLOCK_BYTE {
		diag.err(&d, "ue3.bad-fragment",
			fmt.aprintf("the byte before the bounds is %d, not %d", block_byte, FRAGMENT_BLOCK_BYTE))
		return
	}

	// Bounds: origin, extent, radius.
	origin: [3]f32
	extent: [3]f32
	for axis in 0 ..< 3 {
		origin[axis] = read_f32(r)
	}
	for axis in 0 ..< 3 {
		extent[axis] = read_f32(r)
	}
	radius := read_f32(r)
	if r.failed {
		diag.err(&d, "ue3.bad-fragment", "the fragment ends inside its bounds")
		return
	}
	// A radius is a length: zero is legal (a degenerate box writes -0.0 in this corpus),
	// a negative number is not a length, and a NaN is not one either.
	if !(radius >= 0) || radius > 1e12 {
		diag.err(&d, "ue3.bad-fragment", fmt.aprintf("the bounds radius is %f", radius))
		return
	}
	// The centre and the bounds origin are inside the box the hull reports, extended by the
	// bounds extent: a point outside both is a record read at the wrong stride.
	for axis in 0 ..< 3 {
		low := min(mins[axis], origin[axis] - math.abs(extent[axis])) - 1
		high := max(maxs[axis], origin[axis] + math.abs(extent[axis])) + 1
		if fragment.center[axis] < low || fragment.center[axis] > high {
			diag.err(&d, "ue3.bad-fragment",
				fmt.aprintf("the centre on axis %d is outside the hull box", axis))
			return
		}
	}

	// Neighbours: one byte per plane of the hull.
	neighbours, neighbours_ok := read_count(r, 0)
	if !neighbours_ok {
		diag.err(&d, "ue3.bad-fragment", "the neighbour array does not fit the payload")
		return
	}
	if neighbours != planes {
		diag.err(&d, "ue3.bad-fragment",
			fmt.aprintf("%d neighbours for %d hull planes", neighbours, planes))
		return
	}
	fragment.neighbours = neighbours
	for _ in 0 ..< neighbours {
		value := int(read_u8(r))
		if r.failed {
			diag.err(&d, "ue3.bad-fragment", "the neighbour array ends inside itself")
			return
		}
		if value == FRAGMENT_EXTERIOR {
			fragment.exterior += 1
			continue
		}
		if value >= total {
			diag.err(&d, "ue3.bad-fragment",
				fmt.aprintf("a face neighbours fragment %d of %d", value, total))
			return
		}
	}

	// Three flags, as UBOOL.
	for _ in 0 ..< 3 {
		flag := read_i32(r)
		if r.failed || (flag != 0 && flag != 1) {
			diag.err(&d, "ue3.bad-fragment", "a fragment flag is not a boolean")
			return
		}
	}
	for _ in 0 ..< 3 {
		value := read_f32(r)
		if !(value == value) || math.abs(value) > 1e6 {
			diag.err(&d, "ue3.bad-fragment", "the exterior normal is not finite")
			return
		}
	}
	dims, dims_ok := read_count(r, 0)
	if !dims_ok {
		diag.err(&d, "ue3.bad-fragment", "the neighbour sizes do not fit the payload")
		return
	}
	if dims != neighbours {
		diag.err(&d, "ue3.bad-fragment",
			fmt.aprintf("%d neighbour sizes for %d neighbours", dims, neighbours))
		return
	}
	fragment.dims = dims
	for _ in 0 ..< dims {
		value := read_f32(r)
		if !(value == value) || value < 0 || value > 1e6 {
			diag.err(&d, "ue3.bad-fragment", "a neighbour size is not a distance")
			return
		}
	}
	return
}

// read_count reads a TArray count and skips the records when their stride is known. A
// count of zero is a legal empty array; a count whose records would run past the payload is
// not, and fails here rather than at the end of the mesh.
read_count :: proc(r: ^Reader, stride: int) -> (count: int, ok: bool) {
	count = int(read_i32(r))
	if r.failed || count < 0 || count > FRAGMENT_MAX_ARRAY {
		return 0, false
	}
	if stride > 0 {
		if !need(r, count * stride) {
			return 0, false
		}
		r.pos += count * stride
	}
	return count, true
}
