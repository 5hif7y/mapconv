// IR -> T3D.
package t3d

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"

ExportOptions :: struct {
	emit_surface_section: bool,
	// ue_precision writes vectors in the exact "+0000.000000" shape UnrealEd
	// produces; disable for compact, still valid output.
	ue_precision:         bool,
}

DEFAULT_EXPORT_OPTIONS :: ExportOptions {
	emit_surface_section = true,
	ue_precision         = true,
}

Writer :: struct {
	b:    strings.Builder,
	next: int,
	opts: ExportOptions,
	// skipped_foreign counts surface attributes owned by another format.
	skipped_foreign: int,
}

write_line :: proc(w: ^Writer, indent: int, text: string) {
	for _ in 0 ..< indent {
		strings.write_byte(&w.b, '\t')
	}
	strings.write_string(&w.b, text)
	strings.write_string(&w.b, "\r\n")
}

write_name :: proc(w: ^Writer, indent: int, name: string) -> string {
	w.next += 1
	return fmt.aprintf("%s_%d", name, w.next)
}

write_vec :: proc(w: ^Writer, v: geom.Vec3) -> string {
	if w.opts.ue_precision {
		return fmt.aprintf("%+013.6f,%+013.6f,%+013.6f", v.x, v.y, v.z)
	}
	return fmt.aprintf("%s,%s,%s", geom.f64_string(v.x), geom.f64_string(v.y), geom.f64_string(v.z))
}

export_document :: proc(d: ^ir.Document, dg: ^diag.Diagnostics, opts := DEFAULT_EXPORT_OPTIONS) -> string {
	w := Writer {
		opts = opts,
	}
	strings.builder_init(&w.b)

	map_name, has_map_name := ir.property_string(d.metadata.props[:], "map_name")
	if !has_map_name || map_name == "" {
		map_name = "Map"
	}
	if has_map_name {
		write_line(&w, 0, ir.concat("Begin Map Name=", map_name))
	} else {
		write_line(&w, 0, "Begin Map")
	}
	level_name := d.world.id
	if level_name == "" || is_numeric(level_name) {
		level_name = "Level"
	}
	write_line(&w, 0, ir.concat("Begin Level NAME=", level_name))

	for brush_index in d.world.brushes {
		if brush_index < 0 || brush_index >= len(d.brushes) {
			diag.warn(dg, "t3d.dangling-brush", "world references a brush that does not exist", fmt.aprintf("%d", brush_index))
			continue
		}
		write_brush_actor(&w, &d.brushes[brush_index], "Brush", dg)
	}

	for &entity in d.entities {
		if entity.class_name == "worldspawn" {
			diag.warn(dg, "t3d.second-worldspawn", "a second worldspawn entity is exported as a regular actor", entity.id)
		}
		write_actor(&w, &entity, d, dg)
	}

	write_line(&w, 0, "End Level")
	if opts.emit_surface_section {
		write_line(&w, 0, "Begin Surface")
		write_line(&w, 0, "End Surface")
	}
	write_line(&w, 0, "End Map")
	if w.skipped_foreign > 0 {
		diag.info(
			dg,
			"t3d.foreign-surface-data",
			fmt.aprintf("%d source-format surface attribute(s) have no T3D equivalent and were dropped", w.skipped_foreign),
		)
	}
	return strings.to_string(w.b)
}

// Prepared_Brush holds the polygon of every face, computed before any text is
// written so an unwritable brush can be dropped without leaving half a block.
Prepared_Brush :: struct {
	windings: [][]geom.Vec3,
}

prepare_brush :: proc(b: ^ir.Brush, dg: ^diag.Diagnostics, name: string) -> (Prepared_Brush, bool) {
	prepared := Prepared_Brush {
		windings = make([][]geom.Vec3, len(b.faces)),
	}
	planes := ir.brush_planes(b)
	defer delete(planes)
	bounds := geom.aabb_expand(ir.brush_bounds(b), 1)
	for &face, index in b.faces {
		winding := face.winding
		if len(winding) < 3 {
			winding = geom.brush_face_winding(planes[:], index, bounds)
			if len(winding) >= 3 {
				diag.info(dg, "t3d.winding-derived", "polygon vertices were derived from the brush planes", name)
			}
		}
		if len(winding) < 3 {
			diag.warn(
				dg,
				"t3d.brush-dropped",
				"brush dropped: one of its faces has no usable polygon after evaluation",
				name,
			)
			return prepared, false
		}
		prepared.windings[index] = winding[:]
	}
	return prepared, true
}

write_actor :: proc(w: ^Writer, e: ^ir.Entity, d: ^ir.Document, dg: ^diag.Diagnostics) {
	name := actor_name_for(w, e.class_name, e.id)

	// Prepare the brushes first: an actor whose brushes cannot be written must not
	// leave an empty "Begin Actor" in the output.
	usable := make([][2]int, len(e.brushes))
	usable_count := 0
	defer delete(usable)
	for brush_index in e.brushes {
		if brush_index < 0 || brush_index >= len(d.brushes) {
			diag.warn(dg, "t3d.dangling-brush", "entity references a brush that does not exist", name)
			continue
		}
		brush_name := brush_name_for_entity(w, &d.brushes[brush_index], name)
		if _, ok := prepare_brush(&d.brushes[brush_index], dg, brush_name); ok {
			if usable_count < len(usable) {
				usable[usable_count] = [2]int{brush_index, 0}
				usable_count += 1
			}
		}
	}
	usable = usable[:usable_count]
	if len(e.brushes) > 0 && usable_count == 0 {
		diag.warn(dg, "t3d.actor-dropped", "actor dropped: none of its brushes could be written", name)
		return
	}

	write_line(w, 1, ir.concat("Begin Actor Class=", e.class_name, " Name=", name))
	// A brush actor needs its CSG operation on the actor, not on the UModel.
	if len(usable) > 0 {
		first := usable[0][0]
		write_line(w, 2, ir.concat("CsgOper=", csg_op_text(d.brushes[first].op)))
		for slot in usable[1:] {
			if d.brushes[slot[0]].op != d.brushes[first].op {
				diag.warn(
					dg,
					"t3d.mixed-csg-operations",
					"an actor owns brushes with different CSG operations; Unreal stores only one",
					name,
				)
				break
			}
		}
	}
	write_actor_props(w, 2, e)
	for slot in usable {
		brush_index := slot[0]
		brush_name := brush_name_for_entity(w, &d.brushes[brush_index], name)
		prepared_brush, _ := prepare_brush(&d.brushes[brush_index], dg, brush_name)
		write_brush_block(w, 2, &d.brushes[brush_index], &prepared_brush, brush_name, dg)
	}
	write_line(w, 1, "End Actor")
}

write_brush_actor :: proc(w: ^Writer, b: ^ir.Brush, name: string, dg: ^diag.Diagnostics) {
	actor_name := actor_name_for(w, name, b.id)
	brush_name := brush_name_for_entity(w, b, actor_name)
	if b.id == "" {
		brush_name = ir.concat("Model_", actor_name[strings.last_index_byte(actor_name, '_') + 1:])
	}
	prepared, ok := prepare_brush(b, dg, brush_name)
	if !ok {
		diag.warn(dg, "t3d.actor-dropped", "brush actor dropped: its only brush could not be written", actor_name)
		return
	}
	write_line(w, 1, ir.concat("Begin Actor Class=Brush Name=", actor_name))
	write_line(w, 2, ir.concat("CsgOper=", csg_op_text(b.op)))
	write_brush_block(w, 2, b, &prepared, brush_name, dg)
	write_line(w, 1, "End Actor")
}

// actor_name_for keeps an authored name, pairs a numeric id with its class
// ("Brush_7") and only falls back to a counter when there is no id at all.
actor_name_for :: proc(w: ^Writer, class_name, id: string) -> string {
	if id == "" {
		return write_name(w, 0, class_name)
	}
	if is_numeric(id) {
		return ir.concat(class_name, "_", id)
	}
	return id
}

// brush_name_for_entity names the UModel of an entity-owned brush after the
// actor so a round trip keeps the actor/brush pairing readable.
brush_name_for_entity :: proc(w: ^Writer, b: ^ir.Brush, actor_name: string) -> string {
	if b.id != "" && !is_numeric(b.id) {
		return b.id
	}
	// "Brush_7" pairs with "Model_7", matching the engine's own naming.
	if cut := strings.last_index_byte(actor_name, '_'); cut >= 0 {
		return ir.concat("Model_", actor_name[cut + 1:])
	}
	return ir.concat(actor_name, "_Model")
}

write_brush_block :: proc(
	w: ^Writer,
	indent: int,
	b: ^ir.Brush,
	prepared: ^Prepared_Brush,
	brush_name: string,
	dg: ^diag.Diagnostics,
) {
	write_line(w, indent, ir.concat("Begin Brush Name=", brush_name))
	for p in b.props {
		// Internal bookkeeping keys are not part of the T3D representation.
		if p.key == "name" || strings.has_prefix(p.key, "source_") || p.key == "id" {
			continue
		}
		write_line(w, indent + 1, ir.concat(p.key, "=", property_text(p)))
	}
	if len(b.faces) == 0 {
		diag.warn(dg, "t3d.brush-without-faces", "brush has no faces", brush_name)
	}
	write_line(w, indent + 1, "Begin PolyList")
	for &face, index in b.faces {
		write_polygon(w, indent + 2, &face, prepared.windings[index])
	}
	write_line(w, indent + 1, "End PolyList")
	write_line(w, indent, "End Brush")
}

write_polygon :: proc(w: ^Writer, indent: int, f: ^ir.Face, winding: []geom.Vec3) {
	item, has_item := ir.property_string(f.props[:], "t3d.item")
	if !has_item || item == "" {
		item = "OUTSIDE"
	}
	line := ir.concat("Begin Polygon Item=", item)
	if f.material != "" {
		line = ir.concat(line, " Texture=", f.material)
	}
	if flags, has_flags := ir.property_string(f.props[:], "t3d.flags"); has_flags {
		line = ir.concat(line, " Flags=", flags)
	} else if f.flags != 0 {
		line = ir.concat(line, " Flags=", fmt.aprintf("%d", f.flags))
	}
	if link, has_link := ir.property_string(f.props[:], "t3d.link"); has_link {
		line = ir.concat(line, " Link=", link)
	}
	if scale, has_scale := ir.property_string(f.props[:], "t3d.shadowmapscale"); has_scale {
		line = ir.concat(line, " ShadowMapScale=", scale)
	}
	if channels, has_channels := ir.property_string(f.props[:], "t3d.lightingchannels"); has_channels {
		line = ir.concat(line, " LightingChannels=", channels)
	}
	write_line(w, indent, line)

	origin := projection_origin(f.uv, winding)
	write_line(w, indent + 1, ir.concat("Origin   ", write_vec(w, origin)))
	write_line(w, indent + 1, ir.concat("Normal   ", write_vec(w, f.plane.normal)))
	us := f.uv.u_scale == 0 ? 1 : f.uv.u_scale
	vs := f.uv.v_scale == 0 ? 1 : f.uv.v_scale
	write_line(w, indent + 1, ir.concat("TextureU ", write_vec(w, geom.div(f.uv.u, us))))
	write_line(w, indent + 1, ir.concat("TextureV ", write_vec(w, geom.div(f.uv.v, vs))))
	for vertex in winding {
		write_line(w, indent + 1, ir.concat("Vertex   ", write_vec(w, vertex)))
	}
	write_line(w, indent, "End Polygon")
}

// projection_origin recovers the Unreal polygon Base from the IR texture
// projection: texel(p) = dot(p - Base, axis), so dot(Base, axis) must equal the
// negated offset term. The least-norm solution in the plane spanned by u and v is
// used so the point stays near the surface.
projection_origin :: proc(uv: ir.TexProjection, winding: []geom.Vec3) -> geom.Vec3 {
	us := uv.u_scale == 0 ? 1 : uv.u_scale
	vs := uv.v_scale == 0 ? 1 : uv.v_scale
	// dot(Base,u)/us + u_offset == 0  ->  dot(Base,u) = -u_offset*us
	a := -uv.u_offset * us
	b := -uv.v_offset * vs
	uu := geom.dot(uv.u, uv.u)
	uv_dot := geom.dot(uv.u, uv.v)
	vv := geom.dot(uv.v, uv.v)
	det := uu * vv - uv_dot * uv_dot
	if abs(det) < geom.GEOM_EPSILON {
		// Degenerate projection: fall back to a point on the polygon.
		if len(winding) > 0 {
			return winding[0]
		}
		return geom.VEC3_ZERO
	}
	alpha := (a * vv - b * uv_dot) / det
	beta := (b * uu - a * uv_dot) / det
	return geom.add(geom.mul(uv.u, alpha), geom.mul(uv.v, beta))
}

csg_op_text :: proc(op: ir.Csg_Op) -> string {
	switch op {
	case .Add:
		return "CSG_Add"
	case .Subtract:
		return "CSG_Subtract"
	case .Intersect:
		return "CSG_Intersect"
	case .Deintersect:
		return "CSG_Deintersect"
	case .Replace:
		return "CSG_Add"
	}
	return "CSG_Add"
}

write_actor_props :: proc(w: ^Writer, indent: int, e: ^ir.Entity) {
	if e.origin != geom.VEC3_ZERO {
		write_line(w, indent, ir.concat("Location=", fmt.aprintf("(X=%s,Y=%s,Z=%s)", geom.f64_string(e.origin.x), geom.f64_string(e.origin.y), geom.f64_string(e.origin.z))))
	}
	if e.has_rotation {
		write_line(w, indent, ir.concat("Rotation=", fmt.aprintf("(Pitch=%d,Yaw=%d,Roll=%d)", e.rotation.pitch, e.rotation.yaw, e.rotation.roll)))
	}
	for p in e.props {
		switch p.key {
		case "location", "rotation", "prepivot", "csgoper", "archetype":
			continue
		}
		write_line(w, indent, ir.concat(p.key, "=", property_text(p)))
	}
	if archetype, ok := ir.property_string(e.props[:], "Archetype"); ok {
		write_line(w, indent, ir.concat("Archetype=", archetype))
	}
}

property_text :: proc(p: ir.Property) -> string {
	if p.raw != "" {
		return p.raw
	}
	switch v in p.value {
	case string:
		return v
	case f64:
		return geom.f64_string(v)
	case i64:
		return fmt.aprintf("%d", v)
	case bool:
		return v ? "True" : "False"
	case geom.Vec3:
		return fmt.aprintf("(X=%s,Y=%s,Z=%s)", geom.f64_string(v.x), geom.f64_string(v.y), geom.f64_string(v.z))
	case ir.Rotation:
		return fmt.aprintf("(Pitch=%d,Yaw=%d,Roll=%d)", v.pitch, v.yaw, v.roll)
	case ir.Raw:
		return v.text
	case ir.Struct_Value, ir.Array_Value:
		return ""
	}
	return ""
}

is_numeric :: proc(s: string) -> bool {
	_, ok := strconv.parse_int(s)
	return ok
}

// Parse_Int is exported for tests that read generated flags back.
parse_int :: proc(s: string) -> (int, bool) {
	v, ok := strconv.parse_int(strings.trim_space(s))
	return v, ok
}
