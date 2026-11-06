// UModel: the BSP model of a level or of a brush actor.
//
// UModel::Serialize (Engine/Src/UnModel.cpp) writes, in order: bounds, the
// vector and point pools, the BSP nodes, the surfaces, the vertex pool, zones,
// the UPolys reference, the leaf data and the render vertex buffer. The layout
// is verified to the byte against real level models (docs/formats/ue3-package.md).
//
// Two serialization quirks matter:
//   - Vectors/Points/Nodes/Verts use BulkSerialize: element size, count, data.
//     For pre-cooked-version packages the elements are written field by field,
//     so the element size is a struct size, not necessarily the sum of fields.
//   - Surfs is a TTransArray, whose operator writes the owner reference *before*
//     the array count. Missing those 4 bytes shifts every following field.
package ue3

import "core:fmt"
import "core:mem"
import "../diag"

FBoxSphereBounds :: struct {
	origin:        Vec3,
	box_extent:    Vec3,
	sphere_radius: f32,
}

// Plane4 is FPlane: the normal in xyz and the distance in w.
Plane4 :: struct {
	normal: Vec3,
	dist:   f32,
}

Bsp_Node :: struct {
	plane:                     Plane4,
	i_vert_pool:               i32,
	i_surf:                    i32,
	i_vertex_index:            i32,
	component_index:           u16,
	component_node_index:      u16,
	component_element_index:   i32,
	i_back:                    i32,
	i_front:                   i32,
	i_plane:                   i32,
	i_collision_bound:         i32,
	zone:                      [2]u8,
	num_vertices:              u8,
	flags:                     u8,
	i_leaf:                    [2]i32,
}

Bsp_Surf :: struct {
	material:          i32, // FPackageIndex
	poly_flags:        u32,
	p_base:            i32,
	v_normal:          i32,
	v_texture_u:       i32,
	v_texture_v:       i32,
	i_brush_poly:      i32,
	actor:             i32, // FPackageIndex
	plane:             Plane4,
	shadow_map_scale:  f32,
	lighting_channels: u32,
}

Vert :: struct {
	p_vertex:        i32,
	i_side:          i32,
	shadow_texcoord: [2]f32,
	// Absent when the package was cooked for a console; then the reader stops
	// after shadow_texcoord.
	backface_shadow_texcoord: [2]f32,
	has_backface:             bool,
}

Model :: struct {
	export_index:    int,
	bounds:          FBoxSphereBounds,
	vectors:         []Vec3,
	points:          []Vec3,
	nodes:           []Bsp_Node,
	surf_owner:      i32,
	surfs:           []Bsp_Surf,
	verts:           []Vert,
	num_shared_sides: i32,
	num_zones:       i32,
	polys_index:     i32,
	leaf_hulls:      i32,
	leaves:          i32,
	portal_nodes:    i32,
	legacy_edges:    i32,
	vertex_buffer:   i32,
	root_outside:    bool,
	linked:          bool,
	num_unique_vertices: i32,
}

// Bsp_Polygon is one BSP node's polygon resolved through the vertex pool and
// the point table: the level's authored surface, in world space.
Bsp_Polygon :: struct {
	node_index:    int,
	surf_index:    i32,
	plane:         Plane4,
	vertices:      []Vec3,
	material:      i32,
	poly_flags:    u32,
}

read_model :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (model: Model, d: diag.Diagnostics) {
	d = diag.init()
	model.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	defer delete(head_d.items)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}

	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	model.bounds = FBoxSphereBounds{read_vec3(&r), read_vec3(&r), read_f32(&r)}

	bulk := read_bulk_vectors(&r, &model.vectors, 12, allocator)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if !bulk {
		diag.err(&d, "ue3.bad-model", "Vectors is not an array of 12-byte FVectors")
		return
	}
	bulk = read_bulk_vectors(&r, &model.points, 12, allocator)
	if !bulk || r.failed {
		diag.err(&d, "ue3.bad-model", "Points is not an array of 12-byte FVectors")
		return
	}
	if !read_bulk_nodes(&r, &model.nodes, allocator) {
		diag.err(&d, "ue3.bad-model", "Nodes is not an array of 64-byte FBspNodes")
		return
	}

	// Surfs: TTransArray writes the owner reference before the count.
	model.surf_owner = read_i32(&r)
	count := read_i32(&r)
	if r.failed || count < 0 || count > 1_000_000 {
		diag.err(&d, "ue3.bad-model", fmt.aprintf("implausible surface count %d", count))
		return
	}
	model.surfs = make([]Bsp_Surf, int(count), allocator)
	for i in 0..<int(count) {
		model.surfs[i] = read_bsp_surf(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
	}

	if !read_bulk_verts(&r, &model.verts, allocator) {
		diag.err(&d, "ue3.bad-model", "Verts is not a 24-byte (or console 16-byte) FVert array")
		return
	}
	model.num_shared_sides = read_i32(&r)
	model.num_zones = read_i32(&r)
	if r.failed || model.num_zones < 0 || model.num_zones > 64 {
		diag.err(&d, "ue3.bad-model", fmt.aprintf("implausible zone count %d", model.num_zones))
		return
	}
	// FZoneProperties: ZoneActor(4) + Connectivity(8) + Visibility(8) + LastRenderTime(4).
	if !need(&r, int(model.num_zones) * 24) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	r.pos += int(model.num_zones) * 24

	model.polys_index = read_i32(&r)
	model.leaf_hulls = skip_bulk(&r)
	model.leaves = skip_bulk(&r)
	model.root_outside = read_i32(&r) != 0
	model.linked = read_i32(&r) != 0
	model.portal_nodes = skip_bulk(&r)
	// Legacy shadow-volume edges exist before version 686, which covers 576.
	model.legacy_edges = skip_bulk(&r)
	model.num_unique_vertices = read_i32(&r)
	model.vertex_buffer = skip_bulk(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if r.pos != head.end_offset {
		diag.warn(
			&d,
			"ue3.model-size-mismatch",
			fmt.aprintf(
				"UModel parsed %d of %d bytes (%+d); the layout may have drifted",
				r.pos - int(e.serial_offset),
				e.serial_size,
				r.pos - head.end_offset,
			),
		)
	}
	return
}

// read_bulk_header reads BulkSerialize's element size and count.
read_bulk_header :: proc(r: ^Reader) -> (element_size, count: i32, ok: bool) {
	element_size = read_i32(r)
	count = read_i32(r)
	if r.failed {
		return 0, 0, false
	}
	if element_size < 0 || element_size > 512 || count < 0 || count > 1_000_000 {
		return 0, 0, false
	}
	return element_size, count, true
}

// skip_bulk consumes a bulk array without interpreting it and returns its count.
skip_bulk :: proc(r: ^Reader) -> i32 {
	element_size, count, ok := read_bulk_header(r)
	if !ok {
		if !r.failed {
			reader_fail(r, "implausible bulk array header")
		}
		return 0
	}
	if !need(r, int(element_size) * int(count)) {
		return 0
	}
	r.pos += int(element_size) * int(count)
	return count
}

read_bulk_vectors :: proc(r: ^Reader, out: ^[]Vec3, expected: i32, allocator: mem.Allocator) -> bool {
	element_size, count, ok := read_bulk_header(r)
	if !ok {
		if !r.failed {
			reader_fail(r, "implausible bulk array header")
		}
		return false
	}
	if element_size != expected {
		return false
	}
	out^ = make([]Vec3, int(count), allocator)
	for i in 0..<int(count) {
		out[i] = read_vec3(r)
	}
	return !r.failed
}

read_bulk_nodes :: proc(r: ^Reader, out: ^[]Bsp_Node, allocator: mem.Allocator) -> bool {
	element_size, count, ok := read_bulk_header(r)
	if !ok {
		if !r.failed {
			reader_fail(r, "implausible bulk array header")
		}
		return false
	}
	if element_size != 64 {
		return false
	}
	out^ = make([]Bsp_Node, int(count), allocator)
	for i in 0..<int(count) {
		out[i] = read_bsp_node(r)
	}
	return !r.failed
}

read_bulk_verts :: proc(r: ^Reader, out: ^[]Vert, allocator: mem.Allocator) -> bool {
	element_size, count, ok := read_bulk_header(r)
	if !ok {
		if !r.failed {
			reader_fail(r, "implausible bulk array header")
		}
		return false
	}
	if element_size != 24 && element_size != 16 {
		return false
	}
	out^ = make([]Vert, int(count), allocator)
	for i in 0..<int(count) {
		v: Vert
		v.p_vertex = read_i32(r)
		v.i_side = read_i32(r)
		v.shadow_texcoord = [2]f32{read_f32(r), read_f32(r)}
		if element_size == 24 {
			v.backface_shadow_texcoord = [2]f32{read_f32(r), read_f32(r)}
			v.has_backface = true
		}
		out[i] = v
	}
	return !r.failed
}

read_plane4 :: proc(r: ^Reader) -> Plane4 {
	return Plane4{read_vec3(r), read_f32(r)}
}

read_bsp_node :: proc(r: ^Reader) -> Bsp_Node {
	n: Bsp_Node
	n.plane = read_plane4(r)
	n.i_vert_pool = read_i32(r)
	n.i_surf = read_i32(r)
	n.i_vertex_index = read_i32(r)
	n.component_index = read_u16(r)
	n.component_node_index = read_u16(r)
	n.component_element_index = read_i32(r)
	n.i_back = read_i32(r)
	n.i_front = read_i32(r)
	n.i_plane = read_i32(r)
	n.i_collision_bound = read_i32(r)
	n.zone = [2]u8{read_u8(r), read_u8(r)}
	n.num_vertices = read_u8(r)
	n.flags = read_u8(r)
	n.i_leaf = [2]i32{read_i32(r), read_i32(r)}
	return n
}

read_bsp_surf :: proc(r: ^Reader) -> Bsp_Surf {
	s: Bsp_Surf
	s.material = read_i32(r)
	s.poly_flags = read_u32(r)
	s.p_base = read_i32(r)
	s.v_normal = read_i32(r)
	s.v_texture_u = read_i32(r)
	s.v_texture_v = read_i32(r)
	s.i_brush_poly = read_i32(r)
	s.actor = read_i32(r)
	s.plane = read_plane4(r)
	s.shadow_map_scale = read_f32(r)
	s.lighting_channels = read_u32(r)
	// iLightmassIndex only exists from VER_INTEGRATED_LIGHTMASS (600) on.
	return s
}

// model_polygons resolves every BSP node that carries vertices into a polygon:
// node vertices live in the vertex pool (Verts), and each FVert indexes Points.
model_polygons :: proc(model: ^Model, allocator := context.allocator) -> []Bsp_Polygon {
	out := make([dynamic]Bsp_Polygon, 0, len(model.nodes), allocator)
	for node, node_index in model.nodes {
		n := int(node.num_vertices)
		if n < 3 {
			continue
		}
		start := int(node.i_vert_pool)
		if start < 0 || start + n > len(model.verts) {
			continue
		}
		vertices := make([]Vec3, n, allocator)
		ok := true
		for i in 0..<n {
			point_index := int(model.verts[start + i].p_vertex)
			if point_index < 0 || point_index >= len(model.points) {
				ok = false
				break
			}
			vertices[i] = model.points[point_index]
		}
		if !ok {
			continue
		}
		poly := Bsp_Polygon {
			node_index = node_index,
			surf_index = node.i_surf,
			plane      = node.plane,
			vertices   = vertices,
		}
		if node.i_surf >= 0 && int(node.i_surf) < len(model.surfs) {
			surf := model.surfs[node.i_surf]
			poly.material = surf.material
			poly.poly_flags = surf.poly_flags
		}
		append(&out, poly)
	}
	return out[:]
}
