// VMF -> IR.
package vmf

import "core:strconv"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"
import "../xform"

// Keys that VMF stores but the IR keeps as opaque per-face or per-brush data.
FACE_KNOWN_KEYS :: []string{"id", "plane", "material", "uaxis", "vaxis", "rotation", "lightmapscale", "smoothing_groups"}

IMPORT_UNSUPPORTED_SOLID_BLOCKS :: []string{"dispinfo", "hidden", "group"}

import_document :: proc(src, source_path: string) -> (doc: ir.Document, d: diag.Diagnostics) {
	doc = ir.init_document(.Source_VMF, xform.source_1())
	doc.metadata.source_path = source_path
	doc.metadata.variant = "vmf/unknown"
	d = diag.init()

	tree := parse_tree(src, &d, source_path)
	if len(tree.nodes) == 0 {
		diag.err(&d, "vmf.empty", "no blocks found; not a VMF file", source_path)
		return doc, d
	}

	version_seen := false
	for &node in tree.nodes {
		switch node.name {
		case "versioninfo":
			version_seen = true
			import_versioninfo(&node, &doc, &d, source_path)
		case "world":
			import_world(&node, &doc, &d, source_path)
		case "entity":
			import_entity(&node, &doc, &d, source_path)
		case "visgroups", "viewsettings", "cameras", "cordon":
			append_extension(&doc.extensions, ir.concat("vmf.block:", node.name), serialize_node_verbatim(&node))
			diag.info(&d, "vmf.preserved-block", "block preserved as an opaque extension", node.name)
		case:
			append_extension(&doc.extensions, ir.concat("vmf.block:", node.name), serialize_node_verbatim(&node))
			diag.warn(&d, "vmf.unknown-block", "unknown top-level block preserved as an opaque extension", node.name)
		}
	}

	if !version_seen {
		diag.warn(&d, "vmf.no-versioninfo", "no versioninfo block; assuming VMF format 100", source_path)
	}
	if len(doc.world.brushes) == 0 && len(doc.entities) == 0 {
		diag.warn(&d, "vmf.no-geometry", "map contains no solids or entities", source_path)
	}
	return doc, d
}

import_versioninfo :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string) {
	map_version, _ := node_value(n, "mapversion")
	format_version, has_format := node_value(n, "formatversion")
	editor_version, _ := node_value(n, "editorversion")
	dv := normalize_f64(map_version)
	if has_format {
		doc.metadata.variant = ir.concat("vmf/", format_version)
	} else if dv == 400 {
		doc.metadata.variant = "vmf/400 (editor version only)"
		diag.warn(d, "vmf.no-formatversion", "formatversion is missing; treating the file as format 100", path)
	} else {
		doc.metadata.variant = "vmf/unknown"
		diag.warn(d, "vmf.no-formatversion", "formatversion is missing", path)
	}
	if editor_version != "" {
		ir.push_property(&doc.metadata.props, "editorversion", editor_version, editor_version)
	}
	if map_version != "" {
		ir.push_property(&doc.metadata.props, "mapversion", map_version, map_version)
	}
}

normalize_f64 :: proc(s: string) -> f64 {
	v, ok := strconv.parse_f64(strings.trim_space(s))
	return v if ok else 0
}

import_world :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string) {
	doc.world.id = id_of(n)
	doc.world.origin, _ = parse_vec3_kv(n, "origin")
	doc.world.angles, _ = parse_vec3_kv(n, "angles")
	import_kv_props(n, &doc.world.props, FACE_KNOWN_KEYS)

	for &child in n.children {
		if child.is_block && child.name == "solid" {
			index := import_solid(&child, doc, d, path, "world.solid")
			append(&doc.world.brushes, index)
		} else if child.is_block {
			append_extension(&doc.world.extensions, ir.concat("vmf.block:", child.name), serialize_node_verbatim(&child))
			diag.warn(d, "vmf.unknown-world-block", "world block preserved as an opaque extension", child.name)
		}
	}
}

import_entity :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string) {
	class_name, has_class := node_value(n, "classname")
	if !has_class || class_name == "" {
		class_name = "unknown"
		diag.warn(d, "vmf.entity-without-classname", "entity has no classname", id_of(n))
	}
	entity := ir.make_entity(id_of(n), class_name)
	entity.origin, _ = parse_vec3_kv(n, "origin")
	entity.angles, _ = parse_vec3_kv(n, "angles")
	import_kv_props(n, &entity.props, nil)

	if strings.has_prefix(strings.to_upper(class_name), "FUNC_INSTANCE") {
		diag.warn(d, "vmf.instance", "func_instance is preserved as entity data, not resolved", class_name)
	}

	for &child in n.children {
		if !child.is_block {
			continue
		}
		switch child.name {
		case "solid":
			index := import_solid(&child, doc, d, path, "entity.solid")
			append(&entity.brushes, index)
		case "connections":
			append_extension(&entity.extensions, "vmf.block:connections", serialize_node_verbatim(&child))
			diag.info(d, "vmf.preserved-connections", "entity I/O connections preserved as an opaque extension", class_name)
		case:
			append_extension(&entity.extensions, ir.concat("vmf.block:", child.name), serialize_node_verbatim(&child))
			diag.warn(d, "vmf.unknown-entity-block", "entity block preserved as an opaque extension", child.name)
		}
	}
	append(&doc.entities, entity)
}

import_solid :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string, context_path: string) -> int {
	brush := ir.make_brush(id_of(n), .Add)
	object := strings.concatenate({context_path, "[", id_of(n), "]"})

	for &child in n.children {
		if !child.is_block {
			continue
		}
		switch child.name {
		case "side":
			face := import_side(&child, doc, d, path, object)
			if face.plane.normal != geom.VEC3_ZERO {
				append(&brush.faces, face)
			}
		case "editor":
			append_extension(&brush.extensions, "vmf.block:editor", serialize_node_verbatim(&child))
		case:
			for unsupported in IMPORT_UNSUPPORTED_SOLID_BLOCKS {
				if child.name == unsupported {
					diag.warn(d, "vmf.unsupported-solid-block", "solid child block is not interpreted; preserved only", strings.concatenate({object, ".", child.name}))
				}
			}
			append_extension(&brush.extensions, ir.concat("vmf.block:", child.name), serialize_node_verbatim(&child))
		}
	}

	if len(brush.faces) < 4 {
		diag.warn(d, "vmf.degenerate-solid", "solid has fewer than four sides; it cannot bound a volume", object)
	}

	// Evaluate the windings once, from the authored planes. The result is marked
	// as derived so no exporter treats it as authored geometry.
	planes := ir.brush_planes(&brush)
	defer delete(planes)
	bounds := geom.Aabb{}
	if len(brush.faces) > 0 {
		points := make([dynamic]geom.Vec3, 0, len(brush.faces) * 3)
		for f in brush.faces {
			a, b, c := geom.plane_points(f.plane)
			append(&points, a, b, c)
		}
		bounds = geom.aabb_expand(geom.aabb_from_points(points[:]), 1)
		delete(points)
	}
	for &face, i in brush.faces {
		face.winding = geom.brush_face_winding(planes[:], i, bounds)
		face.winding_source = .Derived
		if len(face.winding) < 3 {
			diag.warn(d, "vmf.face-clipped-away", "face does not survive clipping against the other side planes", object)
		}
	}
	return ir.add_brush(doc, brush)
}

import_side :: proc(n: ^Node, doc: ^ir.Document, d: ^diag.Diagnostics, path: string, object: string) -> ir.Face {
	plane_value, has_plane := node_value(n, "plane")
	plane := geom.Plane{}
	if !has_plane {
		diag.err(d, "vmf.side-without-plane", "side has no plane definition", object)
	} else if p, ok := parse_plane(plane_value); ok {
		plane = p
	} else {
		diag.err(d, "vmf.invalid-plane", "plane definition is not three valid points", strings.concatenate({object, ".plane"}))
	}

	material, _ := node_value(n, "material")
	uv := ir.default_tex_projection()
	if uvalue, ok := node_value(n, "uaxis"); ok {
		if u, scale, offset, parsed := parse_tex_axis(uvalue); parsed {
			uv.u = u
			uv.u_scale = scale
			uv.u_offset = offset
		} else {
			diag.warn(d, "vmf.invalid-uaxis", "uaxis is not a valid texture axis", object)
		}
	}
	if vvalue, ok := node_value(n, "vaxis"); ok {
		if v, scale, offset, parsed := parse_tex_axis(vvalue); parsed {
			uv.v = v
			uv.v_scale = scale
			uv.v_offset = offset
		} else {
			diag.warn(d, "vmf.invalid-vaxis", "vaxis is not a valid texture axis", object)
		}
	}
	if rotation, ok := node_value(n, "rotation"); ok {
		if r, r_ok := strconv.parse_f64(rotation); r_ok {
			uv.rotation = r
		}
	}

	face := ir.make_face(plane, uv, material)
	if value, ok := node_value(n, "lightmapscale"); ok {
		if v, v_ok := strconv.parse_f64(value); v_ok {
			face.lightmap_scale = v
		}
	}
	if value, ok := node_value(n, "smoothing_groups"); ok {
		if v, v_ok := strconv.parse_i64(value); v_ok {
			face.smoothing_groups = int(v)
		}
	}
	// Unknown side keys are preserved verbatim; VMF has no surface-flag field.
	for &child in n.children {
		if child.is_block {
			append_extension(&face.extensions, ir.concat("vmf.block:", child.name), serialize_node_verbatim(&child))
			continue
		}
		known := false
		for key in FACE_KNOWN_KEYS {
			if child.name == key {
				known = true
				break
			}
		}
		if !known {
			// Unknown side keys are namespaced so a foreign-format exporter can tell
			// them apart from its own surface attributes.
			ir.push_property(&face.props, ir.concat("vmf.", child.name), child.value, child.value)
		}
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

// parse_plane accepts "(x y z) (x y z) (x y z)".
parse_plane :: proc(s: string) -> (geom.Plane, bool) {
	nums := make([dynamic]f64, 0, 9)
	defer delete(nums)
	rest := strings.trim_space(s)
	for len(rest) > 0 {
		if rest[0] == '(' {
			rest = rest[1:]
			continue
		}
		if rest[0] == ')' {
			rest = rest[1:]
			continue
		}
		if rest[0] == ' ' || rest[0] == '\t' {
			rest = rest[1:]
			continue
		}
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != ')' {
			end += 1
		}
		v, ok := strconv.parse_f64(rest[:end])
		if !ok {
			return {}, false
		}
		append(&nums, v)
		rest = rest[end:]
	}
	if len(nums) < 9 {
		return {}, false
	}
	p0 := geom.vec3(nums[0], nums[1], nums[2])
	p1 := geom.vec3(nums[3], nums[4], nums[5])
	p2 := geom.vec3(nums[6], nums[7], nums[8])
	return geom.plane_from_points(p0, p1, p2)
}

// parse_tex_axis accepts "[x y z offset] scale".
parse_tex_axis :: proc(s: string) -> (axis: geom.Vec3, scale, offset: f64, ok: bool) {
	open := strings.index_byte(s, '[')
	close := strings.index_byte(s, ']')
	if open < 0 || close < open {
		return {}, 1, 0, false
	}
	inner := strings.trim_space(s[open + 1:close])
	fields := strings.fields(inner, context.temp_allocator)
	if len(fields) < 4 {
		return {}, 1, 0, false
	}
	values: [4]f64
	for i in 0 ..< 4 {
		v, v_ok := strconv.parse_f64(fields[i])
		if !v_ok {
			return {}, 1, 0, false
		}
		values[i] = v
	}
	axis = geom.vec3(values[0], values[1], values[2])
	offset = values[3]
	scale = 1
	tail := strings.trim_space(s[close + 1:])
	if len(tail) > 0 {
		if v, v_ok := strconv.parse_f64(tail); v_ok && v != 0 {
			scale = v
		}
	}
	return axis, scale, offset, true
}

parse_vec3_kv :: proc(n: ^Node, key: string) -> (geom.Vec3, bool) {
	value, ok := node_value(n, key)
	if !ok {
		return geom.VEC3_ZERO, false
	}
	return ir.parse_vec3_loose(value)
}

id_of :: proc(n: ^Node) -> string {
	if id, ok := node_value(n, "id"); ok {
		return id
	}
	return ""
}

import_kv_props :: proc(n: ^Node, props: ^[dynamic]ir.Property, skip: []string) {
	for child in n.children {
		if child.is_block {
			continue
		}
		skipped := false
		for key in skip {
			if child.name == key {
				skipped = true
				break
			}
		}
		if skipped {
			continue
		}
		ir.push_property(props, child.name, child.value, child.value)
	}
}

append_extension :: proc(exts: ^[dynamic]ir.Extension, name, data: string) {
	append(exts, ir.Extension{name = name, data = data})
}

// serialize_node_verbatim re-emits a parsed block so unknown data survives an
// import/export round trip.
serialize_node_verbatim :: proc(n: ^Node) -> string {
	b := strings.builder_make()
	write_node(&b, n, 0)
	return strings.to_string(b)
}

write_node :: proc(b: ^strings.Builder, n: ^Node, indent: int) {
	pad := strings.repeat("  ", indent)
	if n.is_block {
		strings.write_string(b, pad)
		strings.write_string(b, n.name)
		strings.write_string(b, "\n")
		strings.write_string(b, pad)
		strings.write_string(b, "{\n")
		for &child in n.children {
			write_node(b, &child, indent + 1)
		}
		strings.write_string(b, pad)
		strings.write_string(b, "}\n")
		return
	}
	strings.write_string(b, pad)
	strings.write_string(b, "\"")
	strings.write_string(b, escape(n.name))
	strings.write_string(b, "\" \"")
	strings.write_string(b, escape(n.value))
	strings.write_string(b, "\"\n")
}

escape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '"') && !strings.contains_rune(s, '\\') {
		return s
	}
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}
