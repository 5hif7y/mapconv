// CrimeCraft UE3 package -> canonical IR.
//
// This is the first half of the CrimeCraft -> Source direction. It converts the
// readable authoring geometry: one brush per UPolys object (the polygons of a
// brush volume), with the plane and texture projection taken from the polygon.
//
// The visible world of a CrimeCraft map is mostly static meshes and the level's
// BSP model; both need their native object bodies (ULevel/UModel) and are not
// converted yet. The result is therefore a map of brush volumes with a clear
// diagnostic, not a playable map.
package ue3

import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "../diag"
import "../geom"
import "../ir"
import "../xform"

import_document :: proc(data: []u8, source_path: string) -> (doc: ir.Document, d: diag.Diagnostics) {
	doc = ir.init_document(.UE3_Package, xform.unreal_3())
	doc.metadata.source_path = source_path
	// Meshes embedded in the map are named after the map package, mirroring the
	// directory layout that `extract` writes and the QC model path expects.
	map_name := filepath.stem(source_path)

	pkg, pkg_d := parse(data)
	d = pkg_d
	if diag.has_errors(&d) {
		return
	}
	doc.metadata.variant = fmt.aprintf(
		"ue3-package/%d.%d",
		engine_version(&pkg.summary),
		licensee_version(&pkg.summary),
	)

	brushes := 0
	polygons := 0
	degraded := 0
	// UPolys exports that produced brushes. A level model whose Polys is among
	// them already contributed its geometry; reconstructing its BSP on top would
	// duplicate it.
	converted_polys := make(map[int]bool, 32)
	for e, i in pkg.exports {
		if export_class_name(&pkg, e) != "Polys" {
			continue
		}
		set, set_d := read_polys(&pkg, i)
		merge(&d, &set_d)
		if diag.has_errors(&set_d) {
			continue
		}
		if len(set.polygons) == 0 {
			continue
		}

		brush := ir.make_brush(fmt.aprintf("ue3.polys.%d", i), .Add)
		for poly in set.polygons {
			face, ok := face_from_poly(&pkg, poly)
			if !ok {
				degraded += 1
				continue
			}
			append(&brush.faces, face)
			polygons += 1
		}
		if len(brush.faces) < 4 {
			diag.warn(
				&d,
				"ue3.polys-degenerate",
				fmt.aprintf("UPolys export %d yields %d usable face(s); skipped", i, len(brush.faces)),
				export_class_name(&pkg, e),
			)
			continue
		}
		brush_index := ir.add_brush(&doc, brush)
		append(&doc.world.brushes, brush_index)
		brushes += 1
		converted_polys[i] = true
	}

	// Level BSP models: reconstruct convex solid regions from the node tree.
	// Brush models are skipped because their UPolys was already converted.
	bsp_models := 0
	bsp_solids := 0
	bsp_faces := 0
	for e, i in pkg.exports {
		if export_class_name(&pkg, e) != "Model" || !outer_is_level(&pkg, e) {
			continue
		}
		model, model_d := read_model(&pkg, i)
		merge(&d, &model_d)
		if diag.has_errors(&model_d) {
			continue
		}
		if model.polys_index > 0 && converted_polys[int(model.polys_index) - 1] {
			continue
		}
		solids := model_solids(&model)
		if len(solids) == 0 {
			continue
		}
		bsp_models += 1
		for solid, solid_index in solids {
			brush, faces := solid_brush(&pkg, &model, solid, i, solid_index)
			if faces < 4 {
				continue
			}
			brush_index := ir.add_brush(&doc, brush)
			append(&doc.world.brushes, brush_index)
			bsp_solids += 1
			bsp_faces += faces
			brushes += 1
		}
	}
	// Actors: static mesh actors become entities. The class mapping turns a
	// StaticMeshActor into prop_static for Source targets.
	actors_total := 0
	mesh_entities := 0
	helper_meshes := 0
	light_entities := 0
	for e, i in pkg.exports {
		if export_class_name(&pkg, e) != "Level" {
			continue
		}
		level, level_d := read_level(&pkg, i)
		merge(&d, &level_d)
		if diag.has_errors(&level_d) {
			continue
		}
		for actor in level.actors {
			if package_index_kind(actor) != .Export {
				continue
			}
			index := int(actor) - 1
			info, info_d := read_actor_info(&pkg, index)
			merge(&d, &info_d)
			if diag.has_errors(&info_d) {
				continue
			}
			actors_total += 1
			if info.mesh_name == "" {
				// Lights carry their colour and brightness instead of a mesh.
				if info.has_brightness || info.has_light_color {
					light := ir.make_entity("", info.class_name)
					set_actor_transform(&light, info)
					if info.has_brightness {
						ir.push_property(&light.props, "brightness", fmt.aprintf("%g", info.brightness))
					}
					if info.has_light_color {
						c := info.light_color
						ir.push_property(
							&light.props,
							"lightcolor",
							fmt.aprintf("(R=%d,G=%d,B=%d,A=%d)", int(c[2]), int(c[1]), int(c[0]), int(c[3])),
						)
					}
					append(&doc.entities, light)
					light_entities += 1
				}
				continue
			}
			// Collision-only and light-volume meshes are mapper helpers: they have
			// no place in a playable Source map (collision comes from the BSP and
			// models, and light shafts need sprites, not opaque cones).
			mesh_lower := strings.to_lower(info.mesh_name)
			if strings.contains(mesh_lower, "collision") || strings.contains(mesh_lower, "lightbeam") ||
			   strings.contains(mesh_lower, "light_beam") || strings.contains(mesh_lower, "volume") {
				helper_meshes += 1
				continue
			}
			entity := ir.make_entity("", info.class_name)
			set_actor_transform(&entity, info)
			owner := info.mesh_package
			if owner == "" {
				owner = map_name
			}
			ir.push_property(&entity.props, "staticmesh", fmt.aprintf("%s/%s", owner, info.mesh_name))
			append(&doc.entities, entity)
			mesh_entities += 1
		}
	}
	if helper_meshes > 0 {
		diag.info(
			&d,
			"ue3.helper-meshes",
			fmt.aprintf("skipped %d collision/light-volume mesh(es)", helper_meshes),
			source_path,
		)
	}

	if actors_total > 0 {
		diag.info(
			&d,
			"ue3.actors",
			fmt.aprintf(
				"created %d mesh and %d light entity(ies) from %d actor(s); other actors are skipped",
				mesh_entities,
				light_entities,
				actors_total,
			),
			source_path,
		)
	}

	if bsp_solids > 0 {
		diag.info(
			&d,
			"ue3.bsp-solids",
			fmt.aprintf(
				"reconstructed %d solid region(s), %d face(s) from %d level BSP model(s)",
				bsp_solids,
				bsp_faces,
				bsp_models,
			),
			source_path,
		)
	}

	doc.world.id = "1"
	doc.world.class_name = "worldspawn"
	if brushes == 0 {
		diag.err(
			&d,
			"ue3.no-brush-geometry",
			"the package has no readable brush polygons and no reconstructible BSP solids; actors and materials are not converted yet",
			source_path,
		)
		return
	}
	summary := fmt.aprintf("converted %d brush(es): %d UPolys face(s)", brushes, polygons)
	if bsp_solids > 0 {
		summary = fmt.aprintf("%s, %d BSP face(s) from %d solid region(s)", summary, bsp_faces, bsp_solids)
	}
	if mesh_entities > 0 {
		summary = fmt.aprintf("%s, %d mesh entity(ies)", summary, mesh_entities)
	}
	if light_entities > 0 {
		summary = fmt.aprintf("%s, %d light entity(ies)", summary, light_entities)
	}
	diag.info(
		&d,
		"ue3.converted",
		fmt.aprintf("%s; materials and mesh assets are not converted yet", summary),
		source_path,
	)
	if degraded > 0 {
		diag.warn(
			&d,
			"ue3.polys-degenerate",
			fmt.aprintf("%d polygon(s) had a zero-length normal and were dropped", degraded),
			source_path,
		)
	}
	return
}

// set_actor_transform copies the UE3 location and rotation into an entity.
set_actor_transform :: proc(entity: ^ir.Entity, info: Actor_Info) {
	entity.origin = geom.Vec3 {
		f64(info.location[0]),
		f64(info.location[1]),
		f64(info.location[2]),
	}
	if info.has_rotation {
		entity.rotation = ir.Rotation {
			pitch = info.rotation[0],
			yaw   = info.rotation[1],
			roll  = info.rotation[2],
		}
		entity.has_rotation = true
	}
}

// outer_is_level reports whether the export's outer is a Level export.
outer_is_level :: proc(pkg: ^Package, e: Export) -> bool {
	if package_index_kind(e.outer_index) != .Export {
		return false
	}
	index := int(e.outer_index) - 1
	if index < 0 || index >= len(pkg.exports) {
		return false
	}
	return export_class_name(pkg, pkg.exports[index]) == "Level"
}

// solid_brush turns one reconstructed BSP region into an IR brush: every plane
// becomes a face whose winding is the plane clipped by the other planes, with
// the material and texture vectors of the BSP node that produced it.
solid_brush :: proc(
	pkg: ^Package,
	model: ^Model,
	solid: Bsp_Solid,
	model_export: int,
	solid_index: int,
) -> (brush: ir.Brush, faces: int) {
	brush = ir.make_brush(fmt.aprintf("ue3.bsp.%d.%d", model_export, solid_index), .Add)
	if len(solid.planes) < 4 {
		return
	}
	planes := make([]geom.Plane, len(solid.planes))
	defer delete(planes)
	points := make([]geom.Vec3, len(solid.planes))
	defer delete(points)
	for entry, i in solid.planes {
		normal := geom.Vec3{f64(entry.plane.normal.x), f64(entry.plane.normal.y), f64(entry.plane.normal.z)}
		length := geom.length(normal)
		if length < 1e-9 {
			return
		}
		normal = geom.mul(normal, 1 / length)
		planes[i] = geom.Plane{normal = normal, dist = f64(entry.plane.dist) / length}
		points[i] = geom.plane_origin(planes[i])
	}
	bounds := geom.aabb_from_points(points)
	center := geom.aabb_center(bounds)
	radius := 0.0
	for p in points {
		radius = max(radius, geom.length(geom.sub(p, center)))
	}
	bounds = geom.aabb_expand(bounds, radius + 64)

	for plane, i in planes {
		winding := geom.brush_face_winding(planes, i, bounds)
		if len(winding) < 3 {
			delete(winding)
			continue
		}
		material: string
		uv: ir.TexProjection
		flags: u32
		node_index := solid.planes[i].node_index
		if node_index >= 0 && node_index < len(model.nodes) {
			surf_index := model.nodes[node_index].i_surf
			if surf_index >= 0 && int(surf_index) < len(model.surfs) {
				surf := model.surfs[surf_index]
				material = package_index_name(pkg, surf.material)
				uv = uv_from_bsp_surf(model, surf)
				flags = surf.poly_flags
			}
		}
		if material == "" {
			material = "TOOLS/NODRAW"
		}
		face := ir.make_face(plane, uv, material)
		face.flags = flags
		for v in winding {
			append(&face.winding, v)
		}
		delete(winding)
		append(&brush.faces, face)
		faces += 1
	}
	return
}

// uv_from_bsp_surf maps a BSP surface to an IR projection. Unlike FPoly.Base,
// FBspSurf.pBase indexes the model's Points table, so the base really is a world
// point and the projection is exact. UE3 texels are dot(p - base, TextureU).
uv_from_bsp_surf :: proc(model: ^Model, surf: Bsp_Surf) -> ir.TexProjection {
	uv := ir.default_tex_projection()
	if surf.p_base < 0 || int(surf.p_base) >= len(model.points) {
		return uv
	}
	if surf.v_texture_u < 0 || int(surf.v_texture_u) >= len(model.vectors) {
		return uv
	}
	if surf.v_texture_v < 0 || int(surf.v_texture_v) >= len(model.vectors) {
		return uv
	}
	base := model.points[surf.p_base]
	u := model.vectors[surf.v_texture_u]
	v := model.vectors[surf.v_texture_v]
	base3 := geom.Vec3{f64(base.x), f64(base.y), f64(base.z)}
	u3 := geom.Vec3{f64(u.x), f64(u.y), f64(u.z)}
	v3 := geom.Vec3{f64(v.x), f64(v.y), f64(v.z)}
	if lu := geom.length(u3); lu > 1e-9 {
		uv.u = geom.mul(u3, 1 / lu)
		uv.u_scale = 1 / lu
		uv.u_offset = -geom.dot(base3, u3)
	}
	if lv := geom.length(v3); lv > 1e-9 {
		uv.v = geom.mul(v3, 1 / lv)
		uv.v_scale = 1 / lv
		uv.v_offset = -geom.dot(base3, v3)
	}
	return uv
}

// face_from_poly turns one FPoly into an IR face. The stored normal is
// authoritative and the winding order matches it (FPoly::CalcNormal uses the
// same cross-product convention), but the plane distance must come from a
// winding vertex: FPoly.Base is stored in brush-local space and stays at the
// creation size when the brush is scaled (max |Base| in villyard is 1024 while
// its winding reaches 6144). The winding is world space.
face_from_poly :: proc(pkg: ^Package, poly: Poly) -> (face: ir.Face, ok: bool) {
	if len(poly.vertices) < 3 {
		return {}, false
	}
	n := geom.Vec3{f64(poly.normal.x), f64(poly.normal.y), f64(poly.normal.z)}
	length := geom.length(n)
	if length < 1e-9 {
		return {}, false
	}
	n = geom.mul(n, 1 / length)

	winding := make([dynamic]geom.Vec3, 0, len(poly.vertices))
	for v in poly.vertices {
		append(&winding, geom.Vec3{f64(v.x), f64(v.y), f64(v.z)})
	}
	// Guard against a stored normal that disagrees with the winding: keep the
	// normal, reverse the winding so the face is CCW around it.
	if w := winding_normal(winding[:]); geom.dot(w, n) < 0 {
		for i, j := 0, len(winding) - 1; i < j; i, j = i + 1, j - 1 {
			winding[i], winding[j] = winding[j], winding[i]
		}
	}

	plane := geom.Plane{normal = n, dist = geom.dot(n, winding[0])}
	material := package_index_name(pkg, poly.material_index)
	if material == "" {
		material = "TOOLS/NODRAW"
	}
	face = ir.make_face(plane, uv_from_poly(poly, winding[0]), material)
	face.winding_source = .Authored
	for v in winding {
		append(&face.winding, v)
	}
	delete(winding)
	return face, true
}

// winding_normal is the polygon normal implied by the vertex order, following
// FPoly::CalcNormal.
winding_normal :: proc(vertices: []geom.Vec3) -> geom.Vec3 {
	acc := geom.VEC3_ZERO
	for i in 2..<len(vertices) {
		acc = geom.add(acc, geom.cross(geom.sub(vertices[i - 1], vertices[0]), geom.sub(vertices[i], vertices[0])))
	}
	n, ok := geom.normalize(acc)
	if !ok {
		return geom.VEC3_ZERO
	}
	return n
}

// uv_from_poly maps UE3's texture vectors to an IR projection. UE3 computes
// texels as dot(p - Base, TextureU); the IR computes
// dot(p, u) / u_scale + u_offset, so it needs a normalized axis, its inverse
// scale and an offset. Base is brush-local (see face_from_poly), so the offset
// is anchored at the first winding vertex instead: alignment relative to the
// original brush is approximate until the actor transform is converted.
uv_from_poly :: proc(poly: Poly, anchor: geom.Vec3) -> ir.TexProjection {
	uv := ir.default_tex_projection()
	base := anchor

	u := geom.Vec3{f64(poly.texture_u.x), f64(poly.texture_u.y), f64(poly.texture_u.z)}
	if lu := geom.length(u); lu > 1e-9 {
		uv.u = geom.mul(u, 1 / lu)
		uv.u_scale = 1 / lu
		uv.u_offset = -geom.dot(base, u)
	}
	v := geom.Vec3{f64(poly.texture_v.x), f64(poly.texture_v.y), f64(poly.texture_v.z)}
	if lv := geom.length(v); lv > 1e-9 {
		uv.v = geom.mul(v, 1 / lv)
		uv.v_scale = 1 / lv
		uv.v_offset = -geom.dot(base, v)
	}
	return uv
}

// merge appends another diagnostic list and frees its backing array.
merge :: proc(dst: ^diag.Diagnostics, src: ^diag.Diagnostics) {
	for item in src.items {
		append(&dst.items, item)
		dst.counts[int(item.severity)] += 1
	}
	delete(src.items)
}
