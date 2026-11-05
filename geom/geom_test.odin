package geom

import "core:math"
import "core:testing"

CUBE_MIN :: Vec3{-64, -64, -64}
CUBE_MAX :: Vec3{64, 64, 64}

// cube_planes returns the six outward planes of a cube authored with the
// map-file point order (clockwise seen from the front).
cube_planes :: proc() -> []Plane {
	points := [6][3]Vec3{
		{{64, 64, 64}, {64, -64, 64}, {-64, -64, 64}}, // +Z
		{{-64, -64, -64}, {64, -64, -64}, {64, 64, -64}}, // -Z
		{{64, 64, 64}, {64, 64, -64}, {64, -64, -64}}, // +X
		{{-64, -64, 64}, {-64, -64, -64}, {-64, 64, -64}}, // -X
		{{-64, 64, 64}, {-64, 64, -64}, {64, 64, -64}}, // +Y
		{{64, -64, 64}, {64, -64, -64}, {-64, -64, -64}}, // -Y
	}
	planes := make([]Plane, 6)
	for triple, i in points {
		p, _ := plane_from_points(triple[0], triple[1], triple[2])
		planes[i] = p
	}
	return planes
}

@(test)
test_plane_from_map_points :: proc(t: ^testing.T) {
	planes := cube_planes()
	defer delete(planes)
	expected := []Vec3{{0, 0, 1}, {0, 0, -1}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}}
	for plane, i in planes {
		testing.expectf(t, approx_equal(plane.normal, expected[i], 1e-9), "plane %d normal is %v", i, plane.normal)
		testing.expectf(t, math.abs(plane.dist - 64) < 1e-9, "plane %d dist is %v", i, plane.dist)
	}
}

@(test)
test_plane_points_roundtrip :: proc(t: ^testing.T) {
	planes := cube_planes()
	defer delete(planes)
	for plane in planes {
		a, b, c := plane_points(plane)
		back, ok := plane_from_points(a, b, c)
		testing.expect(t, ok)
		testing.expect(t, approx_equal(back.normal, plane.normal, 1e-9))
		testing.expect(t, math.abs(back.dist - plane.dist) < 1e-9)
	}
}

@(test)
test_plane_from_degenerate_points_fails :: proc(t: ^testing.T) {
	_, ok := plane_from_points({0, 0, 0}, {1, 0, 0}, {2, 0, 0})
	testing.expect(t, !ok, "collinear points must not produce a plane")
}

@(test)
test_brush_face_winding_is_the_cube_square :: proc(t: ^testing.T) {
	planes := cube_planes()
	defer delete(planes)
	bounds := Aabb{CUBE_MIN, CUBE_MAX}
	for i in 0 ..< len(planes) {
		w := brush_face_winding(planes, i, bounds)
		defer delete(w)
		testing.expectf(t, len(w) == 4, "face %d has %d vertices", i, len(w))
		area := polygon_area(w[:])
		testing.expectf(t, math.abs(area - 128 * 128) < 1e-3, "face %d area is %v", i, area)
		n, nok := winding_normal(w[:])
		testing.expect(t, nok)
		testing.expectf(t, dot(n, planes[i].normal) > 0.999, "face %d winding faces the wrong way", i)
	}
}

@(test)
test_orient_winding_flips_reversed_polygon :: proc(t: ^testing.T) {
	w := []Vec3{{0, 0, 0}, {0, 1, 0}, {1, 1, 0}, {1, 0, 0}}
	orient_winding(w, {0, 0, -1})
	n, ok := winding_normal(w)
	testing.expect(t, ok)
	testing.expect(t, n.z < 0, "winding was not reversed")
}

@(test)
test_clip_winding_keeps_inside_half_space :: proc(t: ^testing.T) {
	square := []Vec3{{-1, -1, 0}, {1, -1, 0}, {1, 1, 0}, {-1, 1, 0}}
	clipped := clip_winding(square, Plane{{1, 0, 0}, 0}, 1e-9)
	defer delete(clipped)
	for v in clipped {
		testing.expect(t, v.x <= 1e-9, "point outside the half space survived the clip")
	}
	testing.expect(t, math.abs(polygon_area(clipped[:]) - 2) < 1e-6)
}

@(test)
test_mat3_inverse :: proc(t: ^testing.T) {
	m := mat3_diag(2, -3, 4)
	inv, ok := mat3_inverse(m)
	testing.expect(t, ok)
	product := mat3_mul(m, inv)
	testing.expect(t, approx_equal(product.r0, {1, 0, 0}, 1e-12))
	testing.expect(t, approx_equal(product.r1, {0, 1, 0}, 1e-12))
	testing.expect(t, approx_equal(product.r2, {0, 0, 1}, 1e-12))
}

@(test)
test_f64_string_is_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, f64_string(64.00000000000003), "64")
	testing.expect_value(t, f64_string(0.25), "0.25")
	testing.expect_value(t, f64_string(-0.0), "0")
	testing.expect_value(t, f64_string(1.0 / 3.0), "0.333333")
}

@(test)
test_polygon_area_vector_matches_winding :: proc(t: ^testing.T) {
	w := []Vec3{{0, 0, 0}, {2, 0, 0}, {2, 3, 0}, {0, 3, 0}}
	v := polygon_area_vector(w)
	testing.expect(t, math.abs(v.z - 6) < 1e-9)
}
