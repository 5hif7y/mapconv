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
import "../diag"
import "../geom"
import "../ir"
import "../xform"

import_document :: proc(data: []u8, source_path: string) -> (doc: ir.Document, d: diag.Diagnostics) {
	doc = ir.init_document(.UE3_Package, xform.unreal_3())
	doc.metadata.source_path = source_path

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
	}

	doc.world.id = "1"
	doc.world.class_name = "worldspawn"
	if brushes == 0 {
		diag.err(
			&d,
			"ue3.no-brush-geometry",
			"the package has no readable brush polygons; the level model and actors are not converted yet",
			source_path,
		)
		return
	}
	diag.info(
		&d,
		"ue3.brush-volumes-only",
		fmt.aprintf(
			"converted %d brush volume(s), %d polygon face(s); the level BSP model, actors and materials are not converted yet",
			brushes,
			polygons,
		),
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
