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

@(test)
test_rotator_known_values :: proc(t: ^testing.T) {
	pitch, yaw, roll := source_angles_to_unreal_rotator(0, 90, 0)
	testing.expect_value(t, pitch, i32(0))
	testing.expect_value(t, yaw, i32(-16384))
	testing.expect_value(t, roll, i32(0))

	// Source pitch is positive downwards, Unreal pitch positive upwards.
	p2, _, _ := source_angles_to_unreal_rotator(-30, 0, 0)
	testing.expect_value(t, p2, i32(5461))

	// Roll keeps its sign: both engines roll the up vector towards the right.
	_, _, r2 := source_angles_to_unreal_rotator(0, 0, 45)
	testing.expect_value(t, r2, i32(8192))

	// Values wrap: Source yaw 270 is the same heading as -90, so Unreal yaw +90.
	_, y3, _ := source_angles_to_unreal_rotator(0, 270, 0)
	testing.expect_value(t, y3, i32(16384))
}

@(test)
test_rotator_roundtrip :: proc(t: ^testing.T) {
	samples := [][3]f64{{0, 0, 0}, {12.5, -45, 30}, {-89, 179, 179}, {45, 90, -90}}
	for sample in samples {
		p, y, r := source_angles_to_unreal_rotator(sample[0], sample[1], sample[2])
		bp, by, br := unreal_rotator_to_source_angles(p, y, r)
		testing.expectf(t, math.abs(bp - sample[0]) < 0.01, "pitch %.3f -> %d -> %.3f", sample[0], p, bp)
		testing.expectf(t, math.abs(by - sample[1]) < 0.01, "yaw %.3f -> %d -> %.3f", sample[1], y, by)
		testing.expectf(t, math.abs(br - sample[2]) < 0.01, "roll %.3f -> %d -> %.3f", sample[2], r, br)
	}
}

// source_axes and unreal_axes reproduce the two engine conventions quoted in
// rotator.odin. Comparing them after the Y mirror proves the conversion.
source_axes :: proc(pitch_deg, yaw_deg, roll_deg: f64) -> [3]geom.Vec3 {
	p := pitch_deg * math.PI / 180
	y := yaw_deg * math.PI / 180
	r := roll_deg * math.PI / 180
	sp, cp := math.sincos(p)
	sy, cy := math.sincos(y)
	sr, cr := math.sincos(r)
	return {
		{cp * cy, cp * sy, -sp},
		{-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp},
		{cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp},
	}
}

unreal_axes :: proc(pitch_units, yaw_units, roll_units: i32) -> [3]geom.Vec3 {
	p := f64(pitch_units) * DEGREES_PER_UNREAL_ROTATOR * math.PI / 180
	y := f64(yaw_units) * DEGREES_PER_UNREAL_ROTATOR * math.PI / 180
	r := f64(roll_units) * DEGREES_PER_UNREAL_ROTATOR * math.PI / 180
	sp, cp := math.sincos(p)
	sy, cy := math.sincos(y)
	sr, cr := math.sincos(r)
	return {
		{cp * cy, cp * sy, sp},
		{sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp},
		{-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp},
	}
}

@(test)
test_rotator_matches_engine_matrices :: proc(t: ^testing.T) {
	samples := [][3]f64{{0, 0, 0}, {15, 90, 0}, {-20, 33, 42}, {60, -120, -75}}
	for sample in samples {
		p, y, r := source_angles_to_unreal_rotator(sample[0], sample[1], sample[2])
		src := source_axes(sample[0], sample[1], sample[2])
		ue := unreal_axes(p, y, r)
		for axis in 0 ..< 3 {
			mirrored := geom.vec3(src[axis].x, -src[axis].y, src[axis].z)
			testing.expectf(
				t,
				// Unreal rotators are quantised to 65536 units per turn, so a
				// round-trip through them is accurate to about 5e-5 in a unit axis.
				geom.approx_equal(mirrored, ue[axis], 5e-4),
				"axis %d for angles %v: %v != %v",
				axis,
				sample,
				mirrored,
				ue[axis],
			)
		}
	}
}
