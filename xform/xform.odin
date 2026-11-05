// Package xform owns coordinate systems, unit scales and the explicit
// transformation between them. Adapters never apply sign flips or scale factors
// on their own; they declare a CoordinateSystem and ask this package for the
// transform (see docs/coordinates.md).
package xform

import "../geom"

Handedness :: enum {
	Right,
	Left,
}

// Canonical frame used by the IR: right-handed, +Z up, +X east, +Y north, meters.
//
// CoordinateSystem describes a native frame:
//   canonical_meters = to_canonical * (position / units_per_meter)
//
// to_canonical is a pure orthogonal matrix (rotation and/or reflection); the unit
// scale is kept separate so a conversion can be inspected and reported.
CoordinateSystem :: struct {
	name:            string,
	handedness:      Handedness,
	units_per_meter: f64,
	to_canonical:    geom.Mat3,
	up_axis:         u8, // 0 = X, 1 = Y, 2 = Z
	notes:           string,
}

units_per_meter :: proc(cs: CoordinateSystem) -> f64 {
	return cs.units_per_meter
}

// Source 1: 1 unit == 1 inch, right-handed, +Z up, +X east, +Y north.
SOURCE_UNITS_PER_METER :: 1.0 / 0.0254 // 39.37007874015748

source_1 :: proc() -> CoordinateSystem {
	return {
		name = "source1",
		handedness = .Right,
		units_per_meter = SOURCE_UNITS_PER_METER,
		to_canonical = geom.MAT3_IDENTITY,
		up_axis = 2,
		notes = "Valve Source 1: 1 unit = 1 inch, Z up, right-handed",
	}
}

// Unreal Engine 3: 1 unit == 1 centimeter, left-handed, +Z up, +X forward and
// +Y to the right. Expressed in the right-handed canonical frame that Y axis is
// mirrored, hence diag(1, -1, 1).
UNREAL_3_UNITS_PER_METER :: 100.0

unreal_3 :: proc() -> CoordinateSystem {
	return {
		name = "unreal3",
		handedness = .Left,
		units_per_meter = UNREAL_3_UNITS_PER_METER,
		to_canonical = geom.mat3_diag(1, -1, 1),
		up_axis = 2,
		notes = "Unreal Engine 3: 1 unit = 1 centimeter, Z up, left-handed",
	}
}

// Transform maps native coordinates of one system into another:
//   p_target = linear * p_source * scale + translation
Transform :: struct {
	linear:      geom.Mat3,
	scale:       f64,
	translation: geom.Vec3,
	// mirrored reports that the linear part reverses orientation, so polygon
	// windings have to be reversed to keep them counter-clockwise around their
	// own normal.
	mirrored:    bool,
}

IDENTITY :: Transform{geom.MAT3_IDENTITY, 1, geom.VEC3_ZERO, false}

transform_between :: proc(from, to: CoordinateSystem) -> (Transform, bool) {
	if from.units_per_meter <= 0 || to.units_per_meter <= 0 {
		return IDENTITY, false
	}
	inv, ok := geom.mat3_inverse(to.to_canonical)
	if !ok {
		return IDENTITY, false
	}
	linear := geom.mat3_mul(inv, from.to_canonical)
	return {
			linear = linear,
			scale = to.units_per_meter / from.units_per_meter,
			translation = geom.VEC3_ZERO,
			mirrored = geom.mat3_det(linear) < 0,
		},
		true
}

transform_compose :: proc(outer, inner: Transform) -> Transform {
	// outer(inner(p)) == outer.linear * (inner.linear * p * inner.scale + t) * outer.scale + T
	return {
		linear = geom.mat3_mul(outer.linear, inner.linear),
		scale = outer.scale * inner.scale,
		translation = geom.add(geom.mul(geom.mat3_apply(outer.linear, inner.translation), outer.scale), outer.translation),
		mirrored = outer.mirrored != inner.mirrored,
	}
}

transform_inverse :: proc(t: Transform) -> (Transform, bool) {
	inv, ok := geom.mat3_inverse(t.linear)
	if !ok || t.scale == 0 {
		return IDENTITY, false
	}
	// p = inv.linear * (q - t.translation) / t.scale
	return {
			linear = inv,
			scale = 1.0 / t.scale,
			translation = geom.neg(geom.mul(geom.mat3_apply(inv, t.translation), 1.0 / t.scale)),
			mirrored = t.mirrored,
		},
		true
}

apply_point :: proc(t: Transform, p: geom.Vec3) -> geom.Vec3 {
	return geom.add(geom.mul(geom.mat3_apply(t.linear, p), t.scale), t.translation)
}

apply_vector :: proc(t: Transform, v: geom.Vec3) -> geom.Vec3 {
	return geom.mul(geom.mat3_apply(t.linear, v), t.scale)
}

// apply_plane transforms the plane through three of its points. A mirroring
// transform reverses the orientation encoded by the point order, so the points
// are swapped back; the outward normal then keeps pointing to the same side.
apply_plane :: proc(t: Transform, p: geom.Plane) -> (geom.Plane, bool) {
	a, b, c := geom.plane_points(p)
	ta := apply_point(t, a)
	tb := apply_point(t, b)
	tc := apply_point(t, c)
	if t.mirrored {
		ta, tc = tc, ta
	}
	return geom.plane_from_points(ta, tb, tc)
}

// apply_winding transforms every vertex and reverses the order when the
// transform mirrors space, so the polygon stays counter-clockwise around the
// transformed normal.
apply_winding :: proc(t: Transform, w: []geom.Vec3) -> [dynamic]geom.Vec3 {
	out := make([dynamic]geom.Vec3, 0, len(w))
	for v in w {
		append(&out, apply_point(t, v))
	}
	if t.mirrored {
		for i, j := 0, len(out) - 1; i < j; i, j = i + 1, j - 1 {
			out[i], out[j] = out[j], out[i]
		}
	}
	return out
}

// TexProjection is a world-to-texel linear map plus offsets. It is repeated here
// (instead of importing the IR package) so this package stays dependency free;
// ir.TexProjection has the same layout and is converted at the adapter boundary.
TexProjection :: struct {
	u, v:         geom.Vec3,
	u_offset:     f64,
	v_offset:     f64,
	u_scale:      f64,
	v_scale:      f64,
	rotation:     f64,
}

// apply_tex_projection re-expresses a world-to-texel projection in the target
// frame. Texture coordinates are covectors, so they transform with the inverse
// transpose and divide by the linear scale. Offsets stay untouched: the texel
// value of a physical surface point is preserved exactly, which is what keeps
// texture alignment across a unit or handedness change.
apply_tex_projection :: proc(t: Transform, p: TexProjection) -> (TexProjection, bool) {
	inv, ok := geom.mat3_inverse(t.linear)
	if !ok {
		return p, false
	}
	inv_t := geom.mat3_transpose(inv)
	scale := 1.0 / t.scale
	u := geom.mul(geom.mat3_apply(inv_t, p.u), scale)
	v := geom.mul(geom.mat3_apply(inv_t, p.v), scale)
	return {
		u = u,
		v = v,
		u_offset = p.u_offset,
		v_offset = p.v_offset,
		u_scale = p.u_scale,
		v_scale = p.v_scale,
		rotation = p.rotation,
	}, true
}
