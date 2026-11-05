// BSP -> IR.
package bsp

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"
import "../kv"
import "../xform"

import_document :: proc(data: []u8, source_path: string) -> (doc: ir.Document, d: diag.Diagnostics) {
	doc = ir.init_document(.Source_BSP, xform.source_1())
	doc.metadata.source_path = source_path
	doc.metadata.variant = "source-bsp/unknown"
	d = diag.init()

	file, err := read(data, &d, source_path)
	if err != .None {
		return doc, d
	}
	doc.metadata.variant = ir.concat("source-bsp/", fmt.aprintf("%d", file.version))

	tree_diag := diag.init()
	tree := kv.parse_tree(string(file.entities), &tree_diag, source_path)
	// Entity-lump parse problems are warnings, not fatal: the geometry is still
	// usable, and the entity list is what the user will fix.
	merge_diagnostics(&d, &tree_diag)

	if len(tree.nodes) == 0 {
		diag.err(&d, "bsp.no-entities", "the entity lump is empty; the map cannot be attributed", source_path)
		return doc, d
	}

	decomp := Decompiler {
		file = &file,
	}
	world_models := 0
	for &node in tree.nodes {
		if !node.is_block {
			continue
		}
		block := node
		class_name, has_class := kv.value(&block, "classname")
		if !has_class || class_name == "" {
			diag.warn(&d, "bsp.entity-without-class", "entity without classname skipped", source_path)
			continue
		}
		origin, _ := parse_origin(&block)

		// Entities that reference a brush model own the brushes of that model.
		model_index := -1
		if model, has_model := kv.value(&block, "model"); has_model {
			if strings.has_prefix(model, "*") {
				if parsed, ok := strconv.parse_int(model[1:]); ok {
					model_index = int(parsed)
				}
			} else if model != "" {
				diag.warn(
					&d,
					"bsp.asset-model-reference",
					ir.concat("entity '", class_name, "' references the model '", model, "'; asset references are not converted"),
					class_name,
				)
			}
		}

		if class_name == "worldspawn" {
			doc.world.id = "1"
			doc.world.class_name = "worldspawn"
			doc.world.origin = origin
			import_entity_props(&block, &doc.world.props)
			decompile_world(&decomp, &doc, &d, source_path)
			world_models += 1
			continue
		}

		entity := ir.make_entity("", class_name)
		entity.origin = origin
		import_entity_props(&block, &entity.props)
		if kv_has(&block, "model") {
			// The model key is a BSP internal reference, not an entity property.
			entity.props = without_key(entity.props[:], "model")
		}
		if model_index > 0 && model_index < len(file.models) {
			brush_indices := make([dynamic]int, 0, 8)
			defer delete(brush_indices)
			model_brushes(&file, file.models[model_index], &brush_indices)
			for brush_index in brush_indices {
				brush := brush_from_lump(&file, brush_index, &d, source_path, class_name)
				if len(brush.faces) >= 4 {
					append(&entity.brushes, ir.add_brush(&doc, brush))
				}
			}
		}
		append(&doc.entities, entity)
	}

	if world_models == 0 {
		diag.warn(&d, "bsp.no-worldspawn", "no worldspawn entity; world geometry was not decompiled", source_path)
	}
	if file.dispinfo_count > 0 {
		diag.warn(
			&d,
			"bsp.displacements",
			fmt.aprintf("%d displacements are not converted; their base surfaces are exported", file.dispinfo_count),
			source_path,
		)
	}
	if decomp.side_textures_approximated > 0 {
		diag.warn(
			&d,
			"bsp.side-texture-approximated",
			fmt.aprintf(
				"%d brush sides carried several textures; the largest face's material was kept",
				decomp.side_textures_approximated,
			),
			source_path,
		)
	}
	if decomp.skipped_leafs > 0 {
		diag.info(
			&d,
			"bsp.leafs-skipped",
			fmt.aprintf("%d solid leaves produced no valid brush", decomp.skipped_leafs),
			source_path,
		)
	}
	return doc, d
}

parse_origin :: proc(n: ^kv.Node) -> (geom.Vec3, bool) {
	value, ok := kv.value(n, "origin")
	if !ok {
		return geom.VEC3_ZERO, false
	}
	return ir.parse_vec3_loose(value)
}

kv_has :: proc(n: ^kv.Node, key: string) -> bool {
	_, ok := kv.value(n, key)
	return ok
}

without_key :: proc(props: []ir.Property, key: string) -> [dynamic]ir.Property {
	out := make([dynamic]ir.Property, 0, len(props))
	for p in props {
		if strings.equal_fold(p.key, key) {
			continue
		}
		append(&out, p)
	}
	return out
}

import_entity_props :: proc(n: ^kv.Node, props: ^[dynamic]ir.Property) {
	for child in n.children {
		if child.is_block {
			continue
		}
		switch strings.to_lower(child.name) {
		case "classname", "origin", "id":
			continue
		}
		ir.push_property(props, child.name, child.value, child.value)
	}
}

merge_diagnostics :: proc(into: ^diag.Diagnostics, from: ^diag.Diagnostics) {
	for item in from.items {
		append(&into.items, item)
		into.counts[int(item.severity)] += 1
	}
}

// ---------------------------------------------------------------------------
// Authored brushes (brush entities)
// ---------------------------------------------------------------------------

brush_from_lump :: proc(f: ^File, index: int, dg: ^diag.Diagnostics, path: string, owner: string) -> ir.Brush {
	brush := ir.make_brush("", .Add)
	if index < 0 || index >= len(f.brushes) {
		diag.warn(dg, "bsp.invalid-brush", "brush index out of range", owner)
		return brush
	}
	source_brush := f.brushes[index]
	brush.props = make([dynamic]ir.Property, 0, 1)
	ir.push_property(&brush.props, "bsp_contents", contents_name(source_brush.contents), contents_name(source_brush.contents))

	planes := make([dynamic]geom.Plane, 0, source_brush.num_sides)
	defer delete(planes)
	for i in 0 ..< source_brush.num_sides {
		slot := source_brush.first_side + i
		if slot < 0 || slot >= len(f.brushsides) {
			break
		}
		side := f.brushsides[slot]
		if side.bevel {
			continue
		}
		if side.plane < 0 || side.plane >= len(f.planes) {
			continue
		}
		plane := f.planes[side.plane]
		append(&planes, geom.Plane{normal = plane.normal, dist = plane.dist})
	}
	if len(planes) < 4 {
		return brush
	}

	// Bounds from the plane points, enough to clip the base windings.
	bounds := bounds_from_planes(planes[:])
	for i in 0 ..< len(planes) {
		slot := i
		// Find the brushside record matching this plane to obtain its texinfo.
		texinfo := -1
		dispinfo := -1
		seen := -1
		for k in 0 ..< source_brush.num_sides {
			side_slot := source_brush.first_side + k
			if side_slot < 0 || side_slot >= len(f.brushsides) {
				break
			}
			side := f.brushsides[side_slot]
			if side.bevel {
				continue
			}
			seen += 1
			if seen == slot {
				texinfo = side.texinfo
				dispinfo = side.dispinfo
				break
			}
		}
		uv := ir.default_tex_projection()
		material := ""
		if texinfo >= 0 && texinfo < len(f.texinfo) {
			info := f.texinfo[texinfo]
			uv = ir.TexProjection {
				u        = info.u,
				v        = info.v,
				u_offset = info.u_offset,
				v_offset = info.v_offset,
				u_scale  = 1,
				v_scale  = 1,
			}
			material, _ = texinfo_of(f, texinfo)
			if material == "" {
				material = "TOOLS/TOOLSNODRAW"
			}
		}
		face := ir.make_face(planes[i], uv, material)
		face.winding = geom.brush_face_winding(planes[:], i, bounds)
		face.winding_source = .Derived
		if dispinfo >= 0 {
			ir.push_property(&face.props, "bsp.displacement", "1", "1")
		}
		append(&brush.faces, face)
	}
	return brush
}

contents_name :: proc(contents: i32) -> string {
	if contents & CONTENTS_SKY != 0 {
		return "sky"
	}
	if contents & CONTENTS_WATER != 0 {
		return "water"
	}
	if contents & CONTENTS_SLIME != 0 {
		return "slime"
	}
	if contents & CONTENTS_LAVA != 0 {
		return "lava"
	}
	if contents & CONTENTS_CLIP != 0 {
		return "clip"
	}
	if contents & CONTENTS_ORIGIN != 0 {
		return "origin"
	}
	return "solid"
}

bounds_from_planes :: proc(planes: []geom.Plane) -> geom.Aabb {
	points := make([dynamic]geom.Vec3, 0, 16)
	defer delete(points)
	for p in planes {
		a, b, c := geom.plane_points(p)
		append(&points, a, b, c)
	}
	return geom.aabb_expand(geom.aabb_from_points(points[:]), 1)
}
