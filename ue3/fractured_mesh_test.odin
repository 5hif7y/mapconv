package ue3

import "core:testing"

import "../diag"

// One FFragmentInfo, built from the layout the two meshes of the corpus were decoded with,
// with every field reachable so a test can break exactly one of them. The record is not
// checked by its length: each falsifier here contradicts one specific cross-check.

Fragment_Offsets :: struct {
	centre:      int,
	vertices:    int, // count
	vertex_data: int,
	permuted:    int,
	permuted_data: int,
	triangles:   int,
	tri_data:    int,
	edges:       int,
	edge_data:   int,
	normals:     int,
	normal_data: int,
	planes:      int,
	plane_data:  int,
	elem_box:    int,
	block_byte:  int,
	bounds:      int,
	radius:      int,
	neighbours:  int,
	nb_data:     int,
	flags:       int,
	exterior_normal: int,
	dims:        int,
	dims_data:   int,
	bytes:       int,
}

frag_put_i32 :: proc(data: []u8, at: int, value: i32) {
	bits := u32(value)
	data[at + 0] = u8(bits)
	data[at + 1] = u8(bits >> 8)
	data[at + 2] = u8(bits >> 16)
	data[at + 3] = u8(bits >> 24)
}

frag_put_f32 :: proc(data: []u8, at: int, value: f32) {
	frag_put_i32(data, at, transmute(i32)value)
}

// build_fragment writes a closed hull: four vertices, one triangle, four planes, four
// neighbours, and the one byte between the box and the bounds.
build_fragment :: proc() -> (data: []u8, at: Fragment_Offsets) {
	data = make([]u8, 512)
	o := 0
	at.centre = o
	o += 12
	at.vertices = o
	frag_put_i32(data, o, 4)
	o += 4
	at.vertex_data = o
	for k in 0 ..< 4 {
		frag_put_f32(data, o + k * 12 + 0, f32(k) * 10)
		frag_put_f32(data, o + k * 12 + 8, 0)
	}
	o += 48
	at.permuted = o
	frag_put_i32(data, o, 3) // (4 / 4) * 3
	o += 4
	at.permuted_data = o
	o += 3 * 16
	at.triangles = o
	frag_put_i32(data, o, 3)
	o += 4
	at.tri_data = o
	frag_put_i32(data, o + 0, 0)
	frag_put_i32(data, o + 4, 1)
	frag_put_i32(data, o + 8, 2)
	o += 12
	at.edges = o
	frag_put_i32(data, o, 1)
	o += 4
	at.edge_data = o
	o += 12
	at.normals = o
	frag_put_i32(data, o, 1)
	o += 4
	at.normal_data = o
	frag_put_f32(data, o + 8, 1)
	o += 12
	at.planes = o
	frag_put_i32(data, o, 4)
	o += 4
	at.plane_data = o
	for k in 0 ..< 4 {
		frag_put_f32(data, o + k * 16 + 3, 5) // distance
	}
	o += 64
	at.elem_box = o
	o += 24
	at.block_byte = o
	data[o] = FRAGMENT_BLOCK_BYTE
	o += 1
	at.bounds = o
	frag_put_f32(data, o + 12, 1) // extent
	at.radius = o + 24
	frag_put_f32(data, o + 24, 2)
	o += 28
	at.neighbours = o
	frag_put_i32(data, o, 4)
	o += 4
	at.nb_data = o
	data[o + 0] = 255
	data[o + 1] = 255
	data[o + 2] = 0
	data[o + 3] = 0
	o += 4
	at.flags = o
	frag_put_i32(data, o, 1)
	o += 12
	at.exterior_normal = o
	frag_put_f32(data, o + 8, -1)
	o += 12
	at.dims = o
	frag_put_i32(data, o, 4)
	o += 4
	at.dims_data = o
	for k in 0 ..< 4 {
		frag_put_f32(data, o + k * 4, 1)
	}
	o += 16
	at.bytes = o
	return data[:o], at
}

read_whole :: proc(data: []u8, total: int) -> (fragment: Fractured_Fragment, d: diag.Diagnostics) {
	return read_fragment(&Reader{data = data, pos = 0, limit = len(data)}, total)
}

@(test)
test_a_fragment_record_decodes_its_hull :: proc(t: ^testing.T) {
	data, _ := build_fragment()
	defer delete(data)
	fragment, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expectf(t, !diag.has_errors(&d), "a clean fragment was refused: %s",
		d.items[0].message if len(d.items) > 0 else "")
	testing.expect_value(t, fragment.vertices, 4)
	testing.expect_value(t, fragment.permuted, 3)
	testing.expect_value(t, fragment.triangles, 1)
	testing.expect_value(t, fragment.faces, 4)
	testing.expect_value(t, fragment.neighbours, 4)
	testing.expect_value(t, fragment.exterior, 2)
}

@(test)
test_a_fragment_whose_permuted_planes_do_not_follow_the_formula_is_refused :: proc(t: ^testing.T) {
	// Four vertices permute into three planes; five would permute into six. A reader that
	// only demanded "the array fits" would take any number.
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.permuted, 4)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect(t, len(d.items) > 0 && d.items[0].code == "ue3.bad-fragment")
}

@(test)
test_a_fragment_whose_neighbours_do_not_match_its_planes_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.neighbours, 3)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "3 neighbours for 4 hull planes")
}

@(test)
test_a_fragment_whose_sizes_do_not_match_its_neighbours_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.dims, 5)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "5 neighbour sizes for 4 neighbours")
}

@(test)
test_a_fragment_that_names_a_fragment_that_does_not_exist_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	data[at.nb_data + 2] = 7 // one neighbour, but the mesh has a single fragment
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "a face neighbours fragment 7 of 1")
}

@(test)
test_a_fragment_whose_triangle_names_a_vertex_that_is_not_there_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.tri_data + 8, 9)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "face index 2 names vertex 9 of 4")
}

@(test)
test_a_fragment_whose_indices_are_not_whole_triangles_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.triangles, 4)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "4 face indices are not whole triangles")
}

@(test)
test_a_fragment_hull_that_is_not_closed_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_i32(data, at.planes, 1)
	frag_put_i32(data, at.neighbours, 1)
	frag_put_i32(data, at.dims, 1)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "a fragment hull has 1 planes")
}

@(test)
test_a_fragment_whose_block_byte_is_not_the_measured_value_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	data[at.block_byte] = 0
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "the byte before the bounds is 0, not 1")
}

@(test)
test_a_fragment_whose_bounds_radius_is_not_a_length_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_f32(data, at.radius, -3)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect(t, len(d.items) > 0 && d.items[0].code == "ue3.bad-fragment")

	nan_data, nan_at := build_fragment()
	defer delete(nan_data)
	frag_put_f32(nan_data, nan_at.radius, transmute(f32)u32(0x7FC00000))
	_, nan_d := read_whole(nan_data, 1)
	defer delete(nan_d.items)
	testing.expect(t, diag.has_errors(&nan_d), "a NaN radius was accepted")
}

@(test)
test_a_fragment_whose_centre_is_outside_its_box_is_refused :: proc(t: ^testing.T) {
	data, at := build_fragment()
	defer delete(data)
	frag_put_f32(data, at.centre + 0, 1000)
	_, d := read_whole(data, 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].message, "the centre on axis 0 is outside the hull box")
}
