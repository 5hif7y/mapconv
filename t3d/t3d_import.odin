// T3D -> IR.
package t3d

import "core:strconv"
import "core:fmt"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"
import "../xform"

import_document :: proc(src, source_path: string) -> (doc: ir.Document, d: diag.Diagnostics) {
	doc = ir.init_document(.Unreal_T3D, xform.unreal_3())
	doc.metadata.source_path = source_path
	doc.metadata.variant = "t3d/ue3"
	d = diag.init()

	tree := parse_tree(src, &d, source_path)
	if len(tree.roots) == 0 {
		diag.err(&d, "t3d.empty", "no blocks found; not a T3D file", source_path)
		return doc, d
	}

	map_seen := false
	for &root in tree.roots {
		if equal_fold(root.keyword, "map") {
			map_seen = true
			if name, ok := node_attr(&root, "name"); ok {
				ir.push_property(&doc.metadata.props, "map_name", name, name)
			}
			for &child in root.children {
				switch {
				case equal_fold(child.keyword, "level"):
					import_level(&child, &doc, &d, source_path)
				case equal_fold(child.keyword, "mappackage"):
					append_ext(&doc.extensions, "t3d.block:mappackage", "native package data is not interpreted")
					diag.warn(
						&d,
						"t3d.map-package",
						"Begin MapPackage holds native package objects; it is preserved as an opaque extension and not converted",
						"map",
					)
				case equal_fold(child.keyword, "surface"):
				// Collected in tree.surface; nothing to import.
				case:
					append_ext(&doc.extensions, ir.concat("t3d.block:", child.keyword), "")
					diag.warn(&d, "t3d.unknown-map-block", "unknown Map child block", child.keyword)
				}
			}
		} else if equal_fold(root.keyword, "surface") {
		// Trailing clipboard surface data; handled below.
		} else if equal_fold(root.keyword, "polygon") || equal_fold(root.keyword, "polylist") {
			// A bare polygon list outside a map is a clipboard fragment.
			diag.warn(&d, "t3d.fragment", "polygon list outside Begin Map; importing it as a world brush", source_path)
			brush := import_polylist(&root, &doc, &d, source_path, "fragment")
			append(&doc.world.brushes, ir.add_brush(&doc, brush))
		} else if root.keyword == "" {
			key := ""
			if len(root.data) > 0 {
				key = root.data[0].key
			}
			diag.warn(&d, "t3d.data-outside-block", "data line outside Begin Map; ignored", key)
		} else {
			append_ext(&doc.extensions, ir.concat("t3d.block:", root.keyword), "")
			diag.warn(&d, "t3d.unknown-root-block", "unknown top-level block", root.keyword)
		}
	}

	if tree.surface_seen {
		diag.info(&d, "t3d.surface-section", "Begin Surface clipboard data is not part of the map geometry", "surface")
	}
	if !map_seen {
		diag.err(&d, "t3d.no-map", "no Begin Map block; the file is not a T3D map", source_path)
	}
	return doc, d
}

import_level :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string) {
	if name, ok := node_attr(n, "name"); ok {
		doc.world.id = name
	}
	doc.world.class_name = "worldspawn"
	for entry in n.data {
		ir.push_property(&doc.world.props, entry.key, entry.value, entry.value)
	}
	for &child in n.children {
		switch {
		case equal_fold(child.keyword, "actor"):
			import_actor(&child, doc, d, path)
		case equal_fold(child.keyword, "brush"):
			// A Brush block directly under the Level is world geometry.
			brush := import_brush(&child, .Add, doc, d, path, "level")
			append(&doc.world.brushes, ir.add_brush(doc, brush))
		case:
			append_ext(&doc.world.extensions, ir.concat("t3d.block:", child.keyword), "")
			diag.warn(d, "t3d.unknown-level-block", "unknown Level child block", child.keyword)
		}
	}
}

import_actor :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string) {
	class_name, has_class := node_attr(n, "class")
	if !has_class || class_name == "" {
		class_name = "unknown"
		diag.warn(d, "t3d.actor-without-class", "Begin Actor without Class; the actor cannot be mapped", ir.concat("line ", strconv_itoa(n.line)))
	}
	name, has_name := node_attr(n, "name")
	if !has_name {
		name = ""
	}
	entity := ir.make_entity(name, class_name)
	if archetype, ok := node_attr(n, "archetype"); ok {
		ir.push_property(&entity.props, "Archetype", archetype, archetype)
	}

	for entry in n.data {
		switch entry.key {
		case "location":
			if v, ok := parse_ue_vec(entry.value); ok {
				entity.origin = v
				ir.push_property(&entity.props, entry.key, v, entry.value)
			} else {
				diag.warn(d, "t3d.invalid-location", "Location is not a valid vector", name)
				ir.push_property(&entity.props, entry.key, entry.value, entry.value)
			}
		case "rotation":
			if r, ok := parse_ue_rotation(entry.value); ok {
				entity.rotation = r
				entity.has_rotation = true
				ir.push_property(&entity.props, entry.key, r, entry.value)
			} else {
				ir.push_property(&entity.props, entry.key, entry.value, entry.value)
			}
		case "prepivot":
			if v, ok := parse_ue_vec(entry.value); ok {
				ir.push_property(&entity.props, entry.key, v, entry.value)
				// PrePivot shifts the brush relative to the actor: subtract it from
				// the actor origin so brush geometry keeps absolute coordinates.
				entity.origin = geom.sub(entity.origin, v)
			} else {
				ir.push_property(&entity.props, entry.key, entry.value, entry.value)
			}
		case:
			ir.push_property(&entity.props, entry.key, entry.value, entry.value)
		}
	}

	for &child in n.children {
		switch {
		case equal_fold(child.keyword, "brush"):
			op := csg_op_from_props(entity.props[:])
			brush := import_brush(&child, op, doc, d, path, name)
			append(&entity.brushes, ir.add_brush(doc, brush))
		case equal_fold(child.keyword, "polylist"):
			op := csg_op_from_props(entity.props[:])
			brush := import_polylist(&child, doc, d, path, name)
			brush.op = op
			append(&entity.brushes, ir.add_brush(doc, brush))
		case equal_fold(child.keyword, "object"):
			// Nested objects (components, subobjects) are preserved verbatim by
			// the exporter path only when the source round trips; for now they are
			// reported and kept as an extension marker.
			append_ext(&entity.extensions, "t3d.child:object", child_attr(&child, "name"))
			diag.warn(
				d,
				"t3d.nested-object",
				"nested Begin Object data is not mapped to the IR and is dropped on export",
				child_attr(&child, "name"),
			)
		case equal_fold(child.keyword, "foliage"):
			append_ext(&entity.extensions, "t3d.child:foliage", "")
			diag.warn(d, "t3d.foliage", "Begin Foliage instances are not converted", name)
		case:
			append_ext(&entity.extensions, ir.concat("t3d.child:", child.keyword), "")
			diag.warn(d, "t3d.unknown-actor-block", "unknown Actor child block", child.keyword)
		}
	}
	append(&doc.entities, entity)
}

child_attr :: proc(n: ^Node, key: string) -> string {
	v, _ := node_attr(n, key)
	return v
}

strconv_itoa :: proc(v: int) -> string {
	return fmt.aprintf("%d", v)
}

import_brush :: proc(n: ^Node, op: ir.Csg_Op, doc: ^ir.Document, d: ^diag.Diagnostics, path: string, owner: string) -> ir.Brush {
	name := child_attr(n, "name")
	brush := ir.make_brush(name, op)
	for entry in n.data {
		ir.push_property(&brush.props, entry.key, entry.value, entry.value)
	}
	for &child in n.children {
		switch {
		case equal_fold(child.keyword, "polylist"):
			polys := import_polylist(&child, doc, d, path, owner)
			for face in polys.faces {
				append(&brush.faces, face)
			}
		case:
			append_ext(&brush.extensions, ir.concat("t3d.child:", child.keyword), "")
			diag.warn(d, "t3d.unknown-brush-block", "unknown Brush child block", child.keyword)
		}
	}
	if len(brush.faces) < 4 {
		diag.warn(d, "t3d.degenerate-brush", "brush has fewer than four polygons", name)
	}
	return brush
}

import_polylist :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string, owner: string) -> ir.Brush {
	brush := ir.make_brush("", .Add)
	for &child in n.children {
		if equal_fold(child.keyword, "polygon") {
			face := import_polygon(&child, doc, d, path, owner)
			if len(face.winding) >= 3 {
				append(&brush.faces, face)
			}
		} else {
			diag.warn(d, "t3d.unknown-polylist-block", "unknown PolyList child block", child.keyword)
		}
	}
	return brush
}

import_polygon :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string, owner: string) -> ir.Face {
	object := ir.concat(owner, ".polygon")
	vertices := make([dynamic]geom.Vec3, 0, 8)
	origin := geom.VEC3_ZERO
	normal := geom.VEC3_ZERO
	tex_u := geom.VEC3_ZERO
	tex_v := geom.VEC3_ZERO
	has_origin := false
	has_normal := false

	for entry in n.data {
		switch entry.key {
		case "vertex":
			if v, ok := parse_ue_vec(entry.value); ok {
				append(&vertices, v)
			} else {
				diag.warn(d, "t3d.invalid-vertex", "vertex is not a valid vector", object)
			}
		case "origin":
			if v, ok := parse_ue_vec(entry.value); ok {
				origin = v
				has_origin = true
			}
		case "normal":
			if v, ok := parse_ue_vec(entry.value); ok {
				normal = v
				has_normal = true
			}
		case "textureu":
			tex_u, _ = parse_ue_vec(entry.value)
		case "texturev":
			tex_v, _ = parse_ue_vec(entry.value)
		case:
			diag.warn(d, "t3d.unknown-polygon-data", "unknown polygon data line preserved", entry.key)
		}
	}

	if len(vertices) < 3 {
		diag.err(d, "t3d.polygon-too-few-vertices", "polygon has fewer than three vertices", object)
		return ir.make_face({}, ir.default_tex_projection(), "")
	}

	derived_normal, normal_ok := geom.normalize(normal)
	if !has_normal || !normal_ok {
		derived_normal, normal_ok = geom.winding_normal(vertices[:])
		if !normal_ok {
			diag.err(d, "t3d.degenerate-polygon", "polygon normal cannot be derived from its vertices", object)
			return ir.make_face({}, ir.default_tex_projection(), "")
		}
		diag.warn(d, "t3d.missing-normal", "polygon has no usable Normal; it was derived from the vertices", object)
	}
	// Unreal stores vertices clockwise when seen from the front in its own
	// left-handed frame; the IR keeps every winding counter-clockwise around its
	// plane normal, so orientation is checked, not assumed.
	geom.orient_winding(vertices[:], derived_normal)

	// The polygon plane goes through its vertices. `Origin` is the texture
	// projection base (FPoly::Base) and is not guaranteed to lie on the plane, so
	// it must not define the plane distance.
	dist := geom.dot(derived_normal, vertices[0])
	plane := geom.Plane{normal = derived_normal, dist = dist}

	uv := ir.TexProjection {
		u        = tex_u,
		v        = tex_v,
		u_offset = -geom.dot(origin, tex_u),
		v_offset = -geom.dot(origin, tex_v),
		u_scale  = 1,
		v_scale  = 1,
	}
	if geom.length_sq(tex_u) < geom.GEOM_EPSILON && geom.length_sq(tex_v) < geom.GEOM_EPSILON {
		diag.warn(d, "t3d.missing-texture-axes", "polygon has no TextureU/TextureV; default projection applied", object)
	}
	material, has_material := node_attr(n, "texture")
	if !has_material || material == "" {
		diag.warn(d, "t3d.polygon-without-texture", "polygon has no Texture attribute", object)
	}
	face := ir.make_face(plane, uv, material)
	face.winding = vertices
	face.winding_source = .Authored

	if item, ok := node_attr(n, "item"); ok {
		ir.push_property(&face.props, "t3d.item", item, item)
	}
	if flags, ok := node_attr(n, "flags"); ok {
		if v, v_ok := parse_ue_int(flags); v_ok {
			face.flags = u32(v)
		}
		ir.push_property(&face.props, "t3d.flags", flags, flags)
	}
	if link, ok := node_attr(n, "link"); ok {
		ir.push_property(&face.props, "t3d.link", link, link)
	}
	if scale, ok := node_attr(n, "shadowmapscale"); ok {
		if v, v_ok := strconv.parse_f64(scale); v_ok {
			face.lightmap_scale = v
		}
		ir.push_property(&face.props, "t3d.shadowmapscale", scale, scale)
	}
	if channels, ok := node_attr(n, "lightingchannels"); ok {
		ir.push_property(&face.props, "t3d.lightingchannels", channels, channels)
	}
	if material != "" {
		register_material(doc, material)
	}
	return face
}

register_material :: proc(doc: ^ir.Document, name: string) {
	if name == "" {
		return
	}
	for m in doc.materials {
		if m.name == name {
			return
		}
	}
	append(&doc.materials, ir.Material{name = name})
}

parse_ue_int :: proc(s: string) -> (i64, bool) {
	text := strings.trim_space(s)
	if len(text) > 2 && (text[:2] == "0x" || text[:2] == "0X") {
		v, ok := strconv.parse_int(text[2:], 16)
		return i64(v), ok
	}
	return strconv.parse_i64(text)
}

// parse_ue_vec accepts "X=1.0,Y=2.0,Z=3.0", "1.0,2.0,3.0" and "(1,2,3)".
parse_ue_vec :: proc(s: string) -> (geom.Vec3, bool) {
	text := strings.trim(strings.trim_space(s), "()")
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) < 3 {
		return geom.VEC3_ZERO, false
	}
	values: [3]f64
	for i in 0 ..< 3 {
		part := strings.trim_space(parts[i])
		if eq := strings.index_byte(part, '='); eq >= 0 {
			part = part[eq + 1:]
		}
		v, ok := strconv.parse_f64(strings.trim_space(part))
		if !ok {
			return geom.VEC3_ZERO, false
		}
		values[i] = v
	}
	return {values[0], values[1], values[2]}, true
}

// parse_ue_rotation accepts "(Pitch=0,Yaw=90,Roll=0)" and "0,90,0".
parse_ue_rotation :: proc(s: string) -> (ir.Rotation, bool) {
	text := strings.trim(strings.trim_space(s), "()")
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) < 3 {
		return {}, false
	}
	values: [3]int
	for i in 0 ..< 3 {
		part := strings.trim_space(parts[i])
		if eq := strings.index_byte(part, '='); eq >= 0 {
			part = part[eq + 1:]
		}
		v, ok := strconv.parse_i64(strings.trim_space(part))
		if !ok {
			return {}, false
		}
		values[i] = int(v)
	}
	return {pitch = i32(values[0]), yaw = i32(values[1]), roll = i32(values[2])}, true
}

csg_op_from_props :: proc(props: []ir.Property) -> ir.Csg_Op {
	value, ok := ir.property_string(props, "csgoper")
	if !ok {
		return .Add
	}
	text := strings.to_upper(strings.trim_space(value))
	switch text {
	case "CSG_SUBTRACT", "SUBTRACT", "2":
		return .Subtract
	case "CSG_INTERSECT", "INTERSECT", "3":
		return .Intersect
	case "CSG_DEINTERSECT", "DEINTERSECT", "4":
		return .Deintersect
	case:
		return .Add
	}
}


