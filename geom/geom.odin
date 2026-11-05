// Package geom holds the engine-independent vector and plane math shared by
// every format adapter. Nothing in this package knows about a native format.
package geom

import "core:fmt"
import "core:math"

// Epsilon used for "is this a valid plane / is this point on the plane" tests.
// Documented in docs/ir.md: geometry tolerances live here and nowhere else.
GEOM_EPSILON :: 1e-6

Vec3 :: struct {
	x, y, z: f64,
}

vec3 :: proc(x, y, z: f64) -> Vec3 {
	return {x, y, z}
}

VEC3_ZERO :: Vec3{0, 0, 0}
VEC3_X :: Vec3{1, 0, 0}
VEC3_Y :: Vec3{0, 1, 0}
VEC3_Z :: Vec3{0, 0, 1}

add :: proc(a, b: Vec3) -> Vec3 {
	return {a.x + b.x, a.y + b.y, a.z + b.z}
}

sub :: proc(a, b: Vec3) -> Vec3 {
	return {a.x - b.x, a.y - b.y, a.z - b.z}
}

mul :: proc(v: Vec3, s: f64) -> Vec3 {
	return {v.x * s, v.y * s, v.z * s}
}

div :: proc(v: Vec3, s: f64) -> Vec3 {
	return {v.x / s, v.y / s, v.z / s}
}

neg :: proc(v: Vec3) -> Vec3 {
	return {-v.x, -v.y, -v.z}
}

dot :: proc(a, b: Vec3) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

cross :: proc(a, b: Vec3) -> Vec3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

length_sq :: proc(v: Vec3) -> f64 {
	return dot(v, v)
}

length :: proc(v: Vec3) -> f64 {
	return math.sqrt(length_sq(v))
}

normalize :: proc(v: Vec3) -> (Vec3, bool) {
	l := length(v)
	if l < GEOM_EPSILON {
		return VEC3_ZERO, false
	}
	return div(v, l), true
}

lerp :: proc(a, b: Vec3, t: f64) -> Vec3 {
	return add(a, mul(sub(b, a), t))
}

approx_equal :: proc(a, b: Vec3, eps: f64 = GEOM_EPSILON) -> bool {
	return length_sq(sub(a, b)) <= eps * eps
}

// Mat3 is stored as rows so that apply() computes a plain matrix-vector product.
Mat3 :: struct {
	r0, r1, r2: Vec3,
}

MAT3_IDENTITY :: Mat3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

mat3_diag :: proc(x, y, z: f64) -> Mat3 {
	return {{x, 0, 0}, {0, y, 0}, {0, 0, z}}
}

mat3_apply :: proc(m: Mat3, v: Vec3) -> Vec3 {
	return {dot(m.r0, v), dot(m.r1, v), dot(m.r2, v)}
}

mat3_mul :: proc(a, b: Mat3) -> Mat3 {
	bt := mat3_transpose(b)
	return {
		{dot(a.r0, bt.r0), dot(a.r0, bt.r1), dot(a.r0, bt.r2)},
		{dot(a.r1, bt.r0), dot(a.r1, bt.r1), dot(a.r1, bt.r2)},
		{dot(a.r2, bt.r0), dot(a.r2, bt.r1), dot(a.r2, bt.r2)},
	}
}

mat3_transpose :: proc(m: Mat3) -> Mat3 {
	return {{m.r0.x, m.r1.x, m.r2.x}, {m.r0.y, m.r1.y, m.r2.y}, {m.r0.z, m.r1.z, m.r2.z}}
}

mat3_det :: proc(m: Mat3) -> f64 {
	return dot(m.r0, cross(m.r1, m.r2))
}

// mat3_inverse returns false for a singular matrix instead of producing garbage.
mat3_inverse :: proc(m: Mat3) -> (Mat3, bool) {
	d := mat3_det(m)
	if math.abs(d) < GEOM_EPSILON {
		return MAT3_IDENTITY, false
	}
	c0 := cross(m.r1, m.r2)
	c1 := cross(m.r2, m.r0)
	c2 := cross(m.r0, m.r1)
	adj := Mat3{c0, c1, c2} // rows already transposed: adjugate of a row-major matrix
	return {
			{adj.r0.x / d, adj.r0.y / d, adj.r0.z / d},
			{adj.r1.x / d, adj.r1.y / d, adj.r1.z / d},
			{adj.r2.x / d, adj.r2.y / d, adj.r2.z / d},
		},
		true
}

// Plane is the classic implicit form: dot(normal, p) = dist, with |normal| == 1.
// The normal points away from the solid the face belongs to.
Plane :: struct {
	normal: Vec3,
	dist:   f64,
}

// plane_from_points follows the three-point convention shared by Valve Map
// Format, Valve 220 and Quake .map files: normal = normalize(cross(p0 - p1, p2 - p1)).
// The points are therefore clockwise seen from the side the normal points to.
plane_from_points :: proc(p0, p1, p2: Vec3) -> (Plane, bool) {
	n, ok := normalize(cross(sub(p0, p1), sub(p2, p1)))
	if !ok {
		return {VEC3_ZERO, 0}, false
	}
	return {n, dot(p1, n)}, true
}

plane_flip :: proc(p: Plane) -> Plane {
	return {neg(p.normal), -p.dist}
}

plane_distance :: proc(p: Plane, v: Vec3) -> f64 {
	return dot(p.normal, v) - p.dist
}

plane_origin :: proc(p: Plane) -> Vec3 {
	return mul(p.normal, p.dist)
}

// plane_basis returns two orthonormal vectors that span the plane and satisfy
// cross(u, v) == normal.
plane_basis :: proc(n: Vec3) -> (u, v: Vec3) {
	helper := math.abs(n.z) < 0.9 ? VEC3_Z : VEC3_X
	u0, _ := normalize(cross(helper, n))
	v0 := cross(n, u0)
	return u0, v0
}

// plane_points returns three points on the plane in the map-file order that
// reproduces `p` through plane_from_points.
plane_points :: proc(p: Plane) -> (p0, p1, p2: Vec3) {
	u, v := plane_basis(p.normal)
	p1 = plane_origin(p)
	p0 = add(p1, u)
	p2 = add(p1, v)
	return
}

// winding_normal is the normal implied by a polygon with the winding convention
// used by both Source and Unreal: cross(v1 - v0, v2 - v0).
winding_normal :: proc(w: []Vec3) -> (Vec3, bool) {
	if len(w) < 3 {
		return VEC3_ZERO, false
	}
	acc := VEC3_ZERO
	for i in 2 ..< len(w) {
		acc = add(acc, cross(sub(w[i - 1], w[0]), sub(w[i], w[0])))
	}
	return normalize(acc)
}

// orient_winding reverses the vertex order in place when it does not match the
// given outward normal, so every winding in the IR is counter-clockwise around
// its own plane normal.
orient_winding :: proc(w: []Vec3, normal: Vec3) {
	n, ok := winding_normal(w)
	if !ok {
		return
	}
	if dot(n, normal) < 0 {
		for i, j := 0, len(w) - 1; i < j; i, j = i + 1, j - 1 {
			w[i], w[j] = w[j], w[i]
		}
	}
}

// base_winding returns a quad that covers a large part of `plane`; clipping it
// against the other planes of a brush yields the actual face polygon.
base_winding :: proc(plane: Plane, radius: f64) -> [dynamic]Vec3 {
	u, v := plane_basis(plane.normal)
	o := plane_origin(plane)
	out := make([dynamic]Vec3, 0, 4)
	append(&out, add(o, add(mul(u, -radius), mul(v, -radius))))
	append(&out, add(o, add(mul(u, radius), mul(v, -radius))))
	append(&out, add(o, add(mul(u, radius), mul(v, radius))))
	append(&out, add(o, add(mul(u, -radius), mul(v, radius))))
	return out
}

// clip_winding keeps the part of the polygon inside (behind) `plane`, using the
// Sutherland-Hodgman algorithm.
clip_winding :: proc(poly: []Vec3, plane: Plane, eps: f64 = GEOM_EPSILON) -> [dynamic]Vec3 {
	out := make([dynamic]Vec3, 0, len(poly) + 1)
	n := len(poly)
	if n == 0 {
		return out
	}
	for i in 0 ..< n {
		cur := poly[i]
		next := poly[(i + 1) % n]
		d_cur := plane_distance(plane, cur)
		d_next := plane_distance(plane, next)
		if d_cur <= eps {
			append(&out, cur)
		}
		if (d_cur > eps && d_next < -eps) || (d_cur < -eps && d_next > eps) {
			t := d_cur / (d_cur - d_next)
			append(&out, lerp(cur, next, t))
		}
	}
	return out
}

Aabb :: struct {
	min, max: Vec3,
}

aabb_from_points :: proc(points: []Vec3) -> Aabb {
	if len(points) == 0 {
		return {{0, 0, 0}, {0, 0, 0}}
	}
	box := Aabb{points[0], points[0]}
	for p in points[1:] {
		box.min.x = math.min(box.min.x, p.x)
		box.min.y = math.min(box.min.y, p.y)
		box.min.z = math.min(box.min.z, p.z)
		box.max.x = math.max(box.max.x, p.x)
		box.max.y = math.max(box.max.y, p.y)
		box.max.z = math.max(box.max.z, p.z)
	}
	return box
}

aabb_center :: proc(b: Aabb) -> Vec3 {
	return mul(add(b.min, b.max), 0.5)
}

aabb_size :: proc(b: Aabb) -> Vec3 {
	return sub(b.max, b.min)
}

aabb_radius :: proc(b: Aabb) -> f64 {
	return length(aabb_size(b)) * 0.5
}

aabb_expand :: proc(b: Aabb, margin: f64) -> Aabb {
	return {sub(b.min, {margin, margin, margin}), add(b.max, {margin, margin, margin})}
}

aabb_corners :: proc(b: Aabb) -> [8]Vec3 {
	return {
		{b.min.x, b.min.y, b.min.z},
		{b.max.x, b.min.y, b.min.z},
		{b.max.x, b.max.y, b.min.z},
		{b.min.x, b.max.y, b.min.z},
		{b.min.x, b.min.y, b.max.z},
		{b.max.x, b.min.y, b.max.z},
		{b.max.x, b.max.y, b.max.z},
		{b.min.x, b.max.y, b.max.z},
	}
}

// brush_face_winding computes the polygon of face `index` of a convex brush
// described by its outward planes. `bounds` is expanded by the caller; it only
// has to be large enough to contain the brush.
brush_face_winding :: proc(planes: []Plane, index: int, bounds: Aabb) -> [dynamic]Vec3 {
	radius := math.max(aabb_radius(bounds) * 2, 64)
	if index < 0 || index >= len(planes) {
		return make([dynamic]Vec3, 0)
	}
	poly := base_winding(planes[index], radius)
	for plane, i in planes {
		if i == index {
			continue
		}
		poly = clip_winding(poly[:], plane)
		if len(poly) == 0 {
			break
		}
	}
	orient_winding(poly[:], planes[index].normal)
	return poly
}

// polygon_area is the vector area of the polygon; its length is the area.
polygon_area_vector :: proc(w: []Vec3) -> Vec3 {
	acc := VEC3_ZERO
	for i in 1 ..< len(w) - 1 {
		acc = add(acc, cross(sub(w[i], w[0]), sub(w[i + 1], w[0])))
	}
	return mul(acc, 0.5)
}

polygon_area :: proc(w: []Vec3) -> f64 {
	return length(polygon_area_vector(w))
}

// f64_string renders a coordinate deterministically: integral values without a
// fractional part, everything else in the shortest round-trippable form. All
// serializers use it so output stays stable across runs and platforms.
f64_string :: proc(v: f64) -> string {
	if math.is_nan(v) || math.is_inf(v) {
		return "0"
	}
	r := v
	// Snap floating point noise from clipping and transformations.
	r = math.round(r * 1e6) / 1e6
	if math.abs(r) < 1e-9 {
		r = 0
	}
	near := math.round(r)
	if math.abs(r - near) < 1e-9 && math.abs(near) < 1e15 {
		return fmt.aprintf("%d", i64(near))
	}
	return fmt.aprintf("%v", r)
}

vec3_string :: proc(v: Vec3, sep: string = " ") -> string {
	return fmt.aprintf("%s%s%s%s%s", f64_string(v.x), sep, f64_string(v.y), sep, f64_string(v.z))
}
