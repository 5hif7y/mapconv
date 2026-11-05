// World brush reconstruction from the BSP tree.
//
// The compiler cut the mapper's brushes along the tree, so a compiled map only
// keeps planes and faces. Each solid leaf is the region behind all the planes on
// the path to it: that region, bounded by the model's bounds, becomes one convex
// brush. A side takes the material and projection of the largest face of the node
// that looks the same way and lies inside the brush; a side no face touches is
// hidden and takes the material of the most opposite side (or the leaf content's
// material), so the map can be compiled again.
//
// The method follows ericw-tools' `bsputil --decompile` (GPL-2.0-or-later); see
// docs/formats/source-bsp.md for the attribution and the licensing note.
package bsp

import "core:math"
import "../diag"
import "../geom"
import "../ir"

Path_Plane :: struct {
	plane: geom.Plane,
	node:  int, // the node the plane comes from, -1 for a model bound
}

Decompiler :: struct {
	file:                       ^File,
	stack:                      [dynamic]Path_Plane,
	leaves:                     [dynamic][]Path_Plane,
	leaf_contents:              [dynamic]i32,
	side_textures_approximated: int,
	skipped_leafs:              int,
}

walk_node :: proc(d: ^Decompiler, node: i32, depth: int) {
	f := d.file
	if node < 0 || int(node) >= len(f.nodes) || depth > 4096 {
		return
	}
	n := f.nodes[node]
	if n.plane < 0 || int(n.plane) >= len(f.planes) {
		return
	}
	base := f.planes[n.plane]
	for front in ([2]bool{true, false}) {
		// Going down the front, the leaf is in front of the plane, so its outward
		// plane is the flipped one.
		plane := geom.Plane{normal = base.normal, dist = base.dist}
		if front {
			plane = geom.plane_flip(plane)
		}
		append(&d.stack, Path_Plane{plane, int(node)})
		child := n.children[0] if front else n.children[1]
		if child < 0 {
			leaf_index := int(-1 - child)
			if leaf_index >= 0 && leaf_index < len(f.leafs) {
				leaf := f.leafs[leaf_index]
				if leaf.contents != CONTENTS_EMPTY {
					path := make([]Path_Plane, len(d.stack))
					copy(path, d.stack[:])
					append(&d.leaves, path)
					append(&d.leaf_contents, leaf.contents)
				}
			}
		} else {
			walk_node(d, child, depth + 1)
		}
		pop(&d.stack)
	}
}

decompile_world :: proc(d: ^Decompiler, doc: ^ir.Document, dg: ^diag.Diagnostics, path: string) {
	f := d.file
	if len(f.models) == 0 {
		diag.warn(dg, "bsp.no-models", "the BSP has no models; world geometry cannot be decompiled", path)
		return
	}
	model := f.models[0]
	if model.headnode < 0 || int(model.headnode) >= len(f.nodes) {
		diag.err(dg, "bsp.invalid-headnode", "model 0 has no valid head node", path)
		return
	}
	// Seed the path with the model bounds so each leaf region is closed.
	for k in 0 ..< 3 {
		plus := [3]f64{0, 0, 0}
		minus := [3]f64{0, 0, 0}
		plus[k] = 1
		minus[k] = -1
		append(&d.stack, Path_Plane{{geom.Vec3{plus[0], plus[1], plus[2]}, model.maxs[k] + 1}, -1})
		append(&d.stack, Path_Plane{{geom.Vec3{minus[0], minus[1], minus[2]}, -(model.mins[k] - 1)}, -1})
	}
	walk_node(d, model.headnode, 0)

	planes := make([dynamic]geom.Plane, 0, 16)
	defer delete(planes)
	for leaf, leaf_index in d.leaves {
		resize(&planes, 0)
		for p in leaf {
			append(&planes, p.plane)
		}
		remove_redundant(&planes, model)
		if len(planes) < 4 {
			d.skipped_leafs += 1
			continue
		}
		build_leaf_brush(d, doc, leaf, planes[:], d.leaf_contents[leaf_index])
	}
}

// remove_redundant drops repeated planes and those that do not bound the region
// behind all of them.
remove_redundant :: proc(planes: ^[dynamic]geom.Plane, model: Model) {
	bounds := model_bounds(model)
	out := 0
	outer: for i in 0 ..< len(planes) {
		for j in 0 ..< out {
			if geom.dot((planes^)[j].normal, (planes^)[i].normal) > 0.99999 &&
			   math.abs((planes^)[j].dist - (planes^)[i].dist) < 0.01 {
				continue outer
			}
		}
		(planes^)[out] = (planes^)[i]
		out += 1
	}
	resize(planes, out)

	keep := make([]bool, len(planes^))
	defer delete(keep)
	for i in 0 ..< len(planes^) {
		poly := geom.base_winding((planes^)[i], math.max(bounds_radius(bounds), 64))
		alive := true
		for j in 0 ..< len(planes^) {
			if i == j {
				continue
			}
			poly = geom.clip_winding(poly[:], (planes^)[j])
			if len(poly) == 0 {
				alive = false
				break
			}
		}
		keep[i] = alive
	}
	out = 0
	for i in 0 ..< len(planes^) {
		if keep[i] {
			(planes^)[out] = (planes^)[i]
			out += 1
		}
	}
	resize(planes, out)
}

model_bounds :: proc(model: Model) -> geom.Aabb {
	return {
		{model.mins[0], model.mins[1], model.mins[2]},
		{model.maxs[0], model.maxs[1], model.maxs[2]},
	}
}

bounds_radius :: proc(b: geom.Aabb) -> f64 {
	return geom.aabb_radius(b)
}

// side_texinfo picks the texinfo of the largest face of `node` that faces the same
// way as `plane` and survives clipping to the brush.
side_texinfo :: proc(d: ^Decompiler, node: int, plane: geom.Plane, planes: []geom.Plane) -> (texinfo: int, ok: bool) {
	f := d.file
	if node < 0 || node >= len(f.nodes) {
		return -1, false
	}
	n := f.nodes[node]
	best_area := 0.0
	best_texinfo := -1
	seen_texinfo := make(map[int]bool, 8)
	defer delete(seen_texinfo)
	for i in n.first_face ..< n.first_face + n.num_faces {
		if i < 0 || i >= len(f.faces) {
			break
		}
		face := f.faces[i]
		winding, normal, winding_ok := face_winding(f, face)
		if !winding_ok {
			continue
		}
		if geom.dot(normal, plane.normal) < 0.9 {
			continue
		}
		clipped := winding
		for other in planes {
			if math.abs(other.dist - plane.dist) < 1e-6 && geom.dot(other.normal, plane.normal) > 0.99999 {
				continue
			}
			clipped = geom.clip_winding(clipped[:], other)
			if len(clipped) == 0 {
				break
			}
		}
		area := geom.polygon_area(clipped[:])
		if area <= 0.01 {
			continue
		}
		seen_texinfo[face.texinfo] = true
		if area > best_area {
			best_area = area
			best_texinfo = face.texinfo
		}
	}
	if len(seen_texinfo) > 1 {
		d.side_textures_approximated += 1
	}
	return best_texinfo, best_texinfo >= 0
}

build_leaf_brush :: proc(d: ^Decompiler, doc: ^ir.Document, path: []Path_Plane, planes: []geom.Plane, contents: i32) {
	bounds := geom.aabb_expand(bounds_from_planes(planes), 1)
	brush := ir.make_brush("", .Add)
	brush.props = make([dynamic]ir.Property, 0, 1)
	ir.push_property(&brush.props, "bsp_contents", contents_name(contents), contents_name(contents))

	side_nodes := make([dynamic]int, 0, 16)
	defer delete(side_nodes)

	for plane, i in planes {
		winding := geom.brush_face_winding(planes, i, bounds)
		if len(winding) < 3 {
			continue
		}
		node := -1
		for p in path {
			if math.abs(p.plane.dist - plane.dist) < 1e-6 && geom.dot(p.plane.normal, plane.normal) > 0.99999 {
				node = p.node
				break
			}
		}
		texinfo, has_face := side_texinfo(d, node, plane, planes)
		material := ""
		uv := ir.default_tex_projection()
		if has_face && texinfo >= 0 && texinfo < len(d.file.texinfo) {
			info := d.file.texinfo[texinfo]
			uv = ir.TexProjection {
				u        = info.u,
				v        = info.v,
				u_offset = info.u_offset,
				v_offset = info.v_offset,
				u_scale  = 1,
				v_scale  = 1,
			}
			material, _ = texinfo_of(d.file, texinfo)
		}
		face := ir.make_face(plane, uv, material)
		face.winding = winding
		face.winding_source = .Derived
		append(&brush.faces, face)
		append(&side_nodes, node)
	}

	// A side no face touches is hidden: take the material of the most opposite
	// side, or the material of the leaf's contents.
	for &face, i in brush.faces {
		if face.material != "" {
			continue
		}
		best := -1
		best_dot := -2.0
		for other, k in brush.faces {
			if other.material == "" || k == i {
				continue
			}
			if dd := geom.dot(geom.neg(face.plane.normal), other.plane.normal); dd > best_dot {
				best = k
				best_dot = dd
			}
		}
		if best >= 0 {
			donor := brush.faces[best]
			face.material = donor.material
			face.uv = donor.uv
		} else {
			face.material = contents_material(contents)
		}
	}

	if len(brush.faces) >= 4 {
		append(&doc.world.brushes, ir.add_brush(doc, brush))
	}
}

contents_material :: proc(contents: i32) -> string {
	if contents & CONTENTS_SKY != 0 {
		return "TOOLS/TOOLSSKYBOX"
	}
	if contents & CONTENTS_WATER != 0 {
		return "TOOLS/TOOLSWATER"
	}
	return "TOOLS/TOOLSNODRAW"
}
