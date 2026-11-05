// Package ir is the canonical, engine-independent map representation. It is the
// only type set that format adapters share; no adapter type may leak into it.
//
// Two rules shape this package:
//   - authoring data (brushes, planes, CSG operations, entities, unknown
//     properties) is preserved as authored, and
//   - evaluated data (face windings, polygons) is kept separate and marked as
//     derived, so evaluation never silently replaces the source model.
//
// docs/ir.md documents every field and its provenance.
package ir

import "../geom"
import "../xform"
import "core:strconv"
import "core:strings"

Format :: enum {
	Unknown,
	Source_VMF,
	Unreal_T3D,
	Goldsrc_MAP,
	Valve_220,
}

format_name :: proc(f: Format) -> string {
	switch f {
	case .Unknown:
		return "unknown"
	case .Source_VMF:
		return "source1-vmf"
	case .Unreal_T3D:
		return "unreal3-t3d"
	case .Goldsrc_MAP:
		return "goldsrc-map"
	case .Valve_220:
		return "valve220"
	}
	return "unknown"
}

// Csg_Op is the authoring operation of a brush. Formats that cannot express a
// subtractive brush lose it, and the exporter must say so.
Csg_Op :: enum {
	Add,
	Subtract,
	Intersect,
	// Deintersect keeps the part of the brush that is outside the world.
	Deintersect,
	Replace,
}

csg_op_name :: proc(op: Csg_Op) -> string {
	switch op {
	case .Add:
		return "add"
	case .Subtract:
		return "subtract"
	case .Intersect:
		return "intersect"
	case .Deintersect:
		return "deintersect"
	case .Replace:
		return "replace"
	}
	return "add"
}

Rotation :: struct {
	pitch, yaw, roll: i32,
}

// Struct_Value and Array_Value are ordered so unknown nested properties can be
// re-serialized without inventing semantics for them.
Struct_Value :: struct {
	fields: [dynamic]Property,
}

Array_Value :: struct {
	items: [dynamic]Value,
}

// Raw keeps text the current IR does not interpret. It is never parsed back.
Raw :: struct {
	text: string,
}

Value :: union {
	string,
	f64,
	i64,
	bool,
	geom.Vec3,
	Rotation,
	Struct_Value,
	Array_Value,
	Raw,
}

Property :: struct {
	key:   string,
	value: Value,
	// raw is the exact source text of the value, kept so unsupported fields
	// survive a conversion even when the typed value was not recognised.
	raw:   string,
}

Extension :: struct {
	name: string,
	data: string,
}

Material :: struct {
	name:       string,
	extensions: [dynamic]Extension,
}

Resource_Kind :: enum {
	Unknown,
	Texture,
	Material,
	Model,
	Sound,
}

Resource :: struct {
	kind:       Resource_Kind,
	reference:  string,
	resolved:   bool,
	note:       string,
}

// TexProjection is the world-to-texel mapping of a face:
//   texel = (dot(position, u) / u_scale + u_offset,
//            dot(position, v) / v_scale + v_offset)
// u_scale and v_scale only preserve the authored Valve axis scale so a VMF
// round trip stays textually stable; the mapping itself is carried by u and v.
TexProjection :: struct {
	u, v:     geom.Vec3,
	u_offset: f64,
	v_offset: f64,
	u_scale:  f64,
	v_scale:  f64,
	rotation: f64,
}

default_tex_projection :: proc() -> TexProjection {
	return {u = geom.VEC3_X, v = geom.VEC3_Y, u_scale = 1, v_scale = 1}
}

texel_at :: proc(p: TexProjection, point: geom.Vec3) -> (u, v: f64) {
	us := p.u_scale == 0 ? 1 : p.u_scale
	vs := p.v_scale == 0 ? 1 : p.v_scale
	return geom.dot(point, p.u) / us + p.u_offset, geom.dot(point, p.v) / vs + p.v_offset
}

Winding_Source :: enum {
	// The native format stored explicit vertices (Unreal T3D polygons).
	Authored,
	// The winding was reconstructed by clipping the brush planes.
	Derived,
}

// Face is one planar side of a brush. `plane` is authored (or reconstructed
// from authored data); `winding` is evaluated geometry and must never be the
// only record of the face.
Face :: struct {
	plane:           geom.Plane,
	winding:         [dynamic]geom.Vec3,
	winding_source:  Winding_Source,
	uv:              TexProjection,
	material:        string,
	// surface flags as the native format spells them; 0 when not present.
	flags:           u32,
	lightmap_scale:  f64,
	smoothing_groups: int,
	props:           [dynamic]Property,
	extensions:      [dynamic]Extension,
}

Brush :: struct {
	id:         string,
	op:         Csg_Op,
	faces:      [dynamic]Face,
	props:      [dynamic]Property,
	extensions: [dynamic]Extension,
}

Entity :: struct {
	id:          string,
	class_name:  string,
	origin:      geom.Vec3,
	angles:      geom.Vec3,
	rotation:    Rotation,
	has_rotation: bool,
	props:       [dynamic]Property,
	brushes:     [dynamic]int,
	children:    [dynamic]int,
	parent:      int,
	extensions:  [dynamic]Extension,
}

Document :: struct {
	metadata:   Metadata,
	cs:         xform.CoordinateSystem,
	brushes:    [dynamic]Brush,
	world:      Entity,
	entities:   [dynamic]Entity,
	materials:  [dynamic]Material,
	resources:  [dynamic]Resource,
	extensions: [dynamic]Extension,
}

Metadata :: struct {
	format:     Format,
	variant:    string,
	source_path: string,
	generator:  string,
	props:      [dynamic]Property,
	notes:      [dynamic]string,
}

GENERATOR :: "mapconv 0.1.0"

init_document :: proc(format: Format, cs: xform.CoordinateSystem) -> Document {
	d := Document {
		cs = cs,
	}
	d.metadata.format = format
	d.metadata.generator = GENERATOR
	d.brushes = make([dynamic]Brush, 0, 8)
	d.entities = make([dynamic]Entity, 0, 8)
	d.materials = make([dynamic]Material, 0, 8)
	d.resources = make([dynamic]Resource, 0, 0)
	d.extensions = make([dynamic]Extension, 0, 0)
	d.metadata.props = make([dynamic]Property, 0, 4)
	d.metadata.notes = make([dynamic]string, 0, 0)
	d.world = make_entity("", "worldspawn")
	return d
}

make_entity :: proc(id, class_name: string) -> Entity {
	e := Entity {
		id         = id,
		class_name = class_name,
		parent     = -1,
	}
	e.props = make([dynamic]Property, 0, 4)
	e.brushes = make([dynamic]int, 0, 2)
	e.children = make([dynamic]int, 0, 0)
	e.extensions = make([dynamic]Extension, 0, 0)
	return e
}

make_brush :: proc(id: string, op: Csg_Op) -> Brush {
	b := Brush {
		id = id,
		op = op,
	}
	b.faces = make([dynamic]Face, 0, 6)
	b.props = make([dynamic]Property, 0, 0)
	b.extensions = make([dynamic]Extension, 0, 0)
	return b
}

make_face :: proc(plane: geom.Plane, uv: TexProjection, material: string) -> Face {
	f := Face {
		plane          = plane,
		uv             = uv,
		material       = material,
		winding_source = .Derived,
		lightmap_scale = 16,
	}
	f.winding = make([dynamic]geom.Vec3, 0, 4)
	f.props = make([dynamic]Property, 0, 0)
	f.extensions = make([dynamic]Extension, 0, 0)
	return f
}

add_brush :: proc(d: ^Document, b: Brush) -> int {
	append(&d.brushes, b)
	return len(d.brushes) - 1
}

add_entity :: proc(d: ^Document, e: Entity) -> int {
	append(&d.entities, e)
	return len(d.entities) - 1
}

// brush_planes returns the outward planes of a brush, one per face.
brush_planes :: proc(b: ^Brush) -> [dynamic]geom.Plane {
	planes := make([dynamic]geom.Plane, 0, len(b.faces))
	for f in b.faces {
		append(&planes, f.plane)
	}
	return planes
}

// brush_bounds derives the bounds from face windings, falling back to the plane
// intersections when a face has no evaluated winding.
brush_bounds :: proc(b: ^Brush, fallback_radius: f64 = 64) -> geom.Aabb {
	points := make([dynamic]geom.Vec3, 0, 16)
	defer delete(points)
	for f in b.faces {
		for v in f.winding {
			append(&points, v)
		}
	}
	if len(points) == 0 {
		// No evaluated geometry: intersect every triple of planes to keep the
		// estimate independent from the face order.
		planes := brush_planes(b)
		defer delete(planes)
		for i in 0 ..< len(planes) {
			for j in i + 1 ..< len(planes) {
				for k in j + 1 ..< len(planes) {
					if p, ok := plane_intersection(planes[i], planes[j], planes[k]); ok {
						inside := true
						for pl in planes {
							if geom.plane_distance(pl, p) > 1 {
								inside = false
								break
							}
						}
						if inside {
							append(&points, p)
						}
					}
				}
			}
		}
		if len(points) == 0 {
			return {{-fallback_radius, -fallback_radius, -fallback_radius}, {fallback_radius, fallback_radius, fallback_radius}}
		}
	}
	return geom.aabb_from_points(points[:])
}

plane_intersection :: proc(a, b, c: geom.Plane) -> (geom.Vec3, bool) {
	bc := geom.cross(b.normal, c.normal)
	denom := geom.dot(a.normal, bc)
	if abs(denom) < geom.GEOM_EPSILON {
		return geom.VEC3_ZERO, false
	}
	ca := geom.cross(c.normal, a.normal)
	ab := geom.cross(a.normal, b.normal)
	return geom.div(
		geom.add(geom.add(geom.mul(bc, a.dist), geom.mul(ca, b.dist)), geom.mul(ab, c.dist)),
		denom,
	), true
}

// property helpers -----------------------------------------------------------

push_property :: proc(props: ^[dynamic]Property, key: string, value: Value, raw := "") {
	append(props, Property{key = key, value = value, raw = raw})
}

find_property :: proc(props: []Property, key: string) -> (^Property, bool) {
	for i in 0 ..< len(props) {
		if props[i].key == key {
			return &props[i], true
		}
	}
	return nil, false
}

property_string :: proc(props: []Property, key: string) -> (string, bool) {
	if p, ok := find_property(props, key); ok {
		if s, sok := p.value.(string); sok {
			return s, true
		}
	}
	return "", false
}

property_f64 :: proc(props: []Property, key: string) -> (f64, bool) {
	if p, ok := find_property(props, key); ok {
		#partial switch v in p.value {
		case f64:
			return v, true
		case i64:
			return f64(v), true
		case string:
			return parse_f64_loose(v)
		}
	}
	return 0, false
}

property_vec3 :: proc(props: []Property, key: string) -> (geom.Vec3, bool) {
	if p, ok := find_property(props, key); ok {
		if v, vok := p.value.(geom.Vec3); vok {
			return v, true
		}
		if s, sok := p.value.(string); sok {
			return parse_vec3_loose(s)
		}
	}
	return geom.VEC3_ZERO, false
}

// parse_f64_loose and parse_vec3_loose accept the text shapes both formats use
// for values the adapter did not type ("1,2,3" and "x y z").
parse_f64_loose :: proc(s: string) -> (f64, bool) {
	v, ok := strconv.parse_f64(strings.trim_space(s))
	return v, ok
}

parse_vec3_loose :: proc(s: string) -> (geom.Vec3, bool) {
	text := strings.trim(strings.trim_space(s), "()")
	fields := strings.fields(text, context.temp_allocator)
	if len(fields) < 3 {
		fields = strings.split(text, ",", context.temp_allocator)
	}
	if len(fields) < 3 {
		return geom.VEC3_ZERO, false
	}
	values: [3]f64
	for i in 0 ..< 3 {
		v, ok := strconv.parse_f64(strings.trim_space(fields[i]))
		if !ok {
			return geom.VEC3_ZERO, false
		}
		values[i] = v
	}
	return {values[0], values[1], values[2]}, true
}

document_bounds :: proc(d: ^Document) -> geom.Aabb {
	points := make([dynamic]geom.Vec3, 0, 64)
	defer delete(points)
	for &b in d.brushes {
		a := brush_bounds(&b)
		for c in geom.aabb_corners(a) {
			append(&points, c)
		}
	}
	if len(points) == 0 {
		return {{0, 0, 0}, {0, 0, 0}}
	}
	return geom.aabb_from_points(points[:])
}

brush_count :: proc(d: ^Document) -> int {
	return len(d.brushes)
}

// entity_class_count counts entities per class name, used by inspect.
entity_class_count :: proc(d: ^Document) -> map[string]int {
	m := make(map[string]int, 8)
	for e in d.entities {
		m[e.class_name] += 1
	}
	m[d.world.class_name] += 1
	return m
}

// concat joins string parts without requiring compile-time constants.
concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}
