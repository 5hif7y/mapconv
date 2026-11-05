package xform

import "core:math"
import "core:testing"
import "../geom"

@(test)
test_source_and_unreal_frames_differ :: proc(t: ^testing.T) {
	s := source_1()
	u := unreal_3()
	testing.expect(t, s.handedness == .Right)
	testing.expect(t, u.handedness == .Left)
	testing.expect(t, math.abs(s.units_per_meter - 39.37007874015748) < 1e-9)
	testing.expect(t, math.abs(u.units_per_meter - 100) < 1e-12)
}

@(test)
test_source_to_unreal_scale_and_mirror :: proc(t: ^testing.T) {
	transform, ok := transform_between(source_1(), unreal_3())
	testing.expect(t, ok)
	testing.expect(t, transform.mirrored)
	testing.expect(t, math.abs(transform.scale - 2.54) < 1e-12)

	// One Source unit is one inch: 64 units become 162.56 Unreal units (cm).
	p := apply_point(transform, {64, 32, 16})
	testing.expect(t, math.abs(p.x - 162.56) < 1e-9)
	testing.expect(t, math.abs(p.y + 81.28) < 1e-9) // Y is mirrored
	testing.expect(t, math.abs(p.z - 40.64) < 1e-9)
}

@(test)
test_roundtrip_is_identity :: proc(t: ^testing.T) {
	forward, _ := transform_between(source_1(), unreal_3())
	back, _ := transform_between(unreal_3(), source_1())
	combined := transform_compose(back, forward)
	p := apply_point(combined, {12.5, -7.25, 33})
	testing.expect(t, geom.approx_equal(p, {12.5, -7.25, 33}, 1e-9))
}

@(test)
test_plane_keeps_outward_side_under_mirror :: proc(t: ^testing.T) {
	transform, _ := transform_between(source_1(), unreal_3())
	// Source floor plane, normal +Z at 64 units.
	top := geom.Plane{{0, 0, 1}, 64}
	moved, ok := apply_plane(transform, top)
	testing.expect(t, ok)
	testing.expect(t, math.abs(moved.normal.z - 1) < 1e-12)
	testing.expect(t, math.abs(moved.dist - 162.56) < 1e-9)

	// A +Y wall has to become a -Y wall after the mirror.
	wall := geom.Plane{{0, 1, 0}, 64}
	moved_wall, ok2 := apply_plane(transform, wall)
	testing.expect(t, ok2)
	testing.expect(t, math.abs(moved_wall.normal.y + 1) < 1e-12)
	testing.expect(t, math.abs(moved_wall.dist - 162.56) < 1e-9)
}

@(test)
test_winding_stays_ccw_around_its_normal :: proc(t: ^testing.T) {
	transform, _ := transform_between(source_1(), unreal_3())
	w := []geom.Vec3{{64, 64, 0}, {64, -64, 0}, {-64, -64, 0}, {-64, 64, 0}}
	before, _ := geom.winding_normal(w)
	moved := apply_winding(transform, w)
	defer delete(moved)
	after, ok := geom.winding_normal(moved[:])
	testing.expect(t, ok)
	expected, _ := apply_plane(transform, geom.Plane{before, geom.dot(before, w[0])})
	testing.expect(t, geom.dot(after, expected.normal) > 0.999)
}

@(test)
test_texture_projection_survives_a_frame_change :: proc(t: ^testing.T) {
	transform, _ := transform_between(source_1(), unreal_3())
	projection := TexProjection {
		u        = {1, 0, 0},
		v        = {0, -1, 0},
		u_offset = 3,
		v_offset = -7,
		u_scale  = 0.25,
		v_scale  = 0.25,
	}
	moved, ok := apply_tex_projection(transform, projection)
	testing.expect(t, ok)

	p := geom.Vec3{32, -16, 8}
	q := apply_point(transform, p)
	texel_u := geom.dot(p, projection.u) / projection.u_scale + projection.u_offset
	texel_v := geom.dot(p, projection.v) / projection.v_scale + projection.v_offset
	moved_u := geom.dot(q, moved.u) / moved.u_scale + moved.u_offset
	moved_v := geom.dot(q, moved.v) / moved.v_scale + moved.v_offset
	testing.expect(t, math.abs(texel_u - moved_u) < 1e-9)
	testing.expect(t, math.abs(texel_v - moved_v) < 1e-9)
}
