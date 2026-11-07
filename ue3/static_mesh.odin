// UStaticMesh geometry: the vertex and index buffers of each LOD.
//
// A static mesh stores its render data in LODModels, an indirect array of
// FStaticMeshRenderData. CrimeCraft's packages are version 576, which predates
// every "modern" buffer layout, so the serialization follows the legacy path
// documented in docs/formats/ue3-package.md:
//
//   Bounds (28), BodySetup (4), legacy kDOP tree, InternalVersion (4),
//   [legacy content tags], LODModels, LODInfo, LODDistanceRatio, ...
//
// Each LOD writes RawTriangles, Elements, the position buffer, the legacy
// interleaved vertex buffer (tangent frame + UVs + color), the legacy shadow
// extrusion buffer, NumVertices, the index buffer, the wireframe buffer, the
// legacy shadow edges and the legacy double-sided flags.
//
// Two details are easy to get wrong:
//   - The position buffer still contains the cloned vertices used to extrude
//     shadow volumes; NumVertices is the real count and the valid positions are
//     the first NumVertices entries.
//   - The legacy vertex and extrusion buffers use BulkSerialize, whose element
//     size is written before the count (element size, count, data).
package ue3

import "core:fmt"
import "core:strings"
import "../xform"
import "../diag"
import "../geom"

// Version gates used by the static mesh reader (Core/Inc/UnObjVer.h).
VER_REMOVED_LEGACY_CONTENT_TAGS :: 593
VER_REMOVED_SHADOW_VOLUMES :: 686
VER_CRACK_FREE_DISPLACEMENT_SUPPORT :: 841
STATICMESH_VERSION_CONTENT_TAGS :: 17

// FStaticMeshTriangle's size at these versions: positions, eight UV sets,
// colors, material/fragment/smoothing bookkeeping and the tangent basis.
STATIC_MESH_TRIANGLE_SIZE :: 272

// FStaticMeshElement, reduced to what the converter needs.
Vec2 :: struct {
	x, y: f32,
}

Static_Mesh_Section :: struct {
	material_name:  string,
	material_ref:   i32, // FPackageIndex of the UMaterialInterface
	material_index: i32,
	first_index:    i32,
	num_triangles:  i32,
	min_vertex:     i32,
	max_vertex:     i32,
}

Static_Mesh_Lod :: struct {
	// Vertices referenced by the index buffer; the position buffer may hold
	// more (legacy shadow volume clones).
	num_vertices:  i32,
	positions:     []Vec3,
	indices:       []u16,
	// UV set 0 of each vertex (the legacy interleaved buffer stores all UV
	// sets; the first one is what a Source material expects).
	uvs:           []Vec2,
	sections:      []Static_Mesh_Section,
	num_tex_coords: i32,
	// Position buffer size before trimming the shadow clones; useful to explain
	// why the buffer is longer than num_vertices.
	position_buffer_count: i32,
}

Static_Mesh :: struct {
	export_index:     int,
	name:             string,
	bounds:           FBoxSphereBounds,
	body_setup:       i32,
	internal_version: i32,
	lods:             []Static_Mesh_Lod,
}

// export_is_static_mesh reports whether an export's class is StaticMesh.
export_is_static_mesh :: proc(pkg: ^Package, e: Export) -> bool {
	return export_class_name(pkg, e) == "StaticMesh"
}

// read_static_mesh deserializes one StaticMesh export. Unsupported package
// versions fail with a diagnostic instead of producing shifted geometry.
read_static_mesh :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (mesh: Static_Mesh, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	version := engine_version(&pkg.summary)
	if version >= VER_REMOVED_SHADOW_VOLUMES {
		diag.err(
			&d,
			"ue3.static-mesh-version",
			fmt.aprintf("static mesh layout is only implemented for versions before %d (got %d)", VER_REMOVED_SHADOW_VOLUMES, version),
		)
		return
	}

	head, head_d := read_object_head(pkg, e, allocator)
	defer delete(head_d.items)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}

	mesh.export_index = export_index
	mesh.name = name_text(pkg, e.object_name)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	mesh.bounds = FBoxSphereBounds{read_vec3(&r), read_vec3(&r), read_f32(&r)}
	mesh.body_setup = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}

	// Legacy kDOP tree: two bulk arrays (nodes of 32 bytes, triangles of 8).
	_ = skip_bulk(&r)
	_ = skip_bulk(&r)
	if r.failed {
		diag.err(&d, "ue3.static-mesh-kdop", r.message)
		return
	}

	mesh.internal_version = read_i32(&r)
	if mesh.internal_version >= STATICMESH_VERSION_CONTENT_TAGS && version < VER_REMOVED_LEGACY_CONTENT_TAGS {
		count := read_i32(&r)
		if count < 0 || count > 100_000 || !need(&r, int(count) * 8) {
			diag.err(&d, "ue3.static-mesh-tags", "implausible legacy content tag count")
			return
		}
		r.pos += int(count) * 8
	}

	lod_count := read_i32(&r)
	if r.failed || lod_count < 0 || lod_count > 32 {
		diag.err(&d, "ue3.static-mesh-lods", fmt.aprintf("implausible LOD count %d", lod_count))
		return
	}
	mesh.lods = make([]Static_Mesh_Lod, int(lod_count), allocator)
	for i in 0..<int(lod_count) {
		lod, lod_d := read_static_mesh_lod(&r, version, allocator)
		if diag.has_errors(&lod_d) {
			for item in lod_d.items {
				diag.add(&d, item.severity, item.code, item.message, item.object, item.loc)
			}
			return
		}
		for &section in lod.sections {
			section.material_name = package_index_name(pkg, section.material_ref)
		}
		mesh.lods[i] = lod
	}
	return
}

// read_static_mesh_lod reads one FStaticMeshRenderData payload.
read_static_mesh_lod :: proc(
	r: ^Reader,
	version: i32,
	allocator := context.allocator,
) -> (lod: Static_Mesh_Lod, d: diag.Diagnostics) {
	d = diag.init()

	// RawTriangles: FUntypedBulkData. Pre-823 packages serialize the elements
	// one by one, after the usual flags/count/size/offset header.
	tri_flags := read_u32(r)
	tri_count := read_i32(r)
	tri_size := read_i32(r)
	tri_offset := read_i32(r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if tri_count < 0 || tri_count > 4_000_000 {
		diag.err(&d, "ue3.static-mesh-triangles", fmt.aprintf("implausible raw triangle count %d", tri_count))
		return
	}
	if tri_flags & BULKDATA_STORE_IN_SEPARATE_FILE != 0 {
		diag.err(&d, "ue3.static-mesh-triangles-streamed", "raw triangles live in a texture file cache")
		return
	}
	if tri_count > 0 {
		if int(tri_offset) != r.pos {
			reader_fail(r, fmt.aprintf("raw triangle payload starts at %d, expected %d", tri_offset, r.pos))
			diag.err(&d, "ue3.static-mesh-triangles-offset", r.message)
			return
		}
		if tri_size != tri_count * STATIC_MESH_TRIANGLE_SIZE || !need(r, int(tri_size)) {
			diag.err(&d, "ue3.static-mesh-triangles-size", "raw triangle payload size does not match its count")
			return
		}
		r.pos += int(tri_size)
	}

	// Elements: submeshes, one per material.
	section_count := read_i32(r)
	if r.failed || section_count < 0 || section_count > 100_000 {
		diag.err(&d, "ue3.static-mesh-elements", fmt.aprintf("implausible element count %d", section_count))
		return
	}
	lod.sections = make([]Static_Mesh_Section, int(section_count), allocator)
	for i in 0..<int(section_count) {
		material := read_i32(r)
		_ = read_i32(r) // EnableCollision
		_ = read_i32(r) // OldEnableCollision
		_ = read_i32(r) // bEnableShadowCasting
		first_index := read_i32(r)
		num_triangles := read_i32(r)
		min_vertex := read_i32(r)
		max_vertex := read_i32(r)
		material_index := read_i32(r)
		fragment_count := read_i32(r)
		if r.failed || fragment_count < 0 || !need(r, int(fragment_count) * 8) {
			diag.err(&d, "ue3.static-mesh-elements", "implausible fragment range count")
			return
		}
		r.pos += int(fragment_count) * 8
		mat := material_index
		if mat == 0 {
			mat = material
		}
		lod.sections[i] = Static_Mesh_Section {
			material_ref   = material,
			material_index = mat,
			first_index    = first_index,
			num_triangles  = num_triangles,
			min_vertex     = min_vertex,
			max_vertex     = max_vertex,
		}
	}

	// Position buffer: Stride, NumVertices, then BulkSerialize (12-byte Vec3).
	stride := read_i32(r)
	count := read_i32(r)
	element_size, bulk_count, ok := read_bulk_header(r)
	if r.failed || !ok || stride != 12 || element_size != 12 || count != bulk_count {
		diag.err(&d, "ue3.static-mesh-positions", "unexpected position buffer layout")
		return
	}
	if !need(r, int(bulk_count) * 12) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	lod.position_buffer_count = bulk_count
	lod.positions = make([]Vec3, int(bulk_count), allocator)
	for i in 0..<int(bulk_count) {
		lod.positions[i] = read_vec3(r)
	}

	// Legacy interleaved vertex buffer: flags, stride and count, then the data.
	num_tex_coords := read_i32(r)
	vertex_stride := read_i32(r)
	vertex_count := read_i32(r)
	full_precision := read_i32(r) != 0
	v_element_size, v_bulk_count, v_ok := read_bulk_header(r)
	if r.failed || !v_ok || v_element_size != vertex_stride || vertex_count != v_bulk_count {
		diag.err(&d, "ue3.static-mesh-vertices", "unexpected legacy vertex buffer layout")
		return
	}
	if !need(r, int(v_bulk_count) * int(vertex_stride)) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	lod.num_tex_coords = num_tex_coords
	// FLegacyStaticMeshFullVertex: TangentX, TangentZ, Color (12 bytes), then
	// NumTexCoords UV pairs (float16, or float32 when bUseFullPrecisionUVs).
	uv_size := 4 if !full_precision else 8
	if num_tex_coords > 0 && int(vertex_stride) == 12 + int(uv_size) * int(num_tex_coords) {
		lod.uvs = make([]Vec2, int(v_bulk_count), allocator)
		for i in 0..<int(v_bulk_count) {
			r.pos += 12
			uv: Vec2
			if full_precision {
				uv = Vec2{read_f32(r), read_f32(r)}
				r.pos += int(uv_size) * (int(num_tex_coords) - 1)
			} else {
				uv = Vec2{half_to_f32(read_u16(r)), half_to_f32(read_u16(r))}
				r.pos += int(uv_size) * (int(num_tex_coords) - 1)
			}
			lod.uvs[i] = uv
		}
	} else {
		r.pos += int(v_bulk_count) * int(vertex_stride)
	}

	// Legacy shadow extrusion buffer.
	extrusion_stride := read_i32(r)
	extrusion_count := read_i32(r)
	e_element_size, e_bulk_count, e_ok := read_bulk_header(r)
	if r.failed || !e_ok || e_element_size != extrusion_stride || extrusion_count != e_bulk_count {
		diag.err(&d, "ue3.static-mesh-extrusion", "unexpected legacy shadow extrusion layout")
		return
	}
	if !need(r, int(e_bulk_count) * int(extrusion_stride)) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	r.pos += int(e_bulk_count) * int(extrusion_stride)

	// NumVertices is the real count: the buffers above still hold the cloned
	// shadow volume vertices, which are the tail of the position buffer.
	num_vertices := read_i32(r)
	if r.failed || num_vertices < 0 || int(num_vertices) > len(lod.positions) {
		diag.err(&d, "ue3.static-mesh-num-vertices", fmt.aprintf("NumVertices %d exceeds the position buffer (%d)", num_vertices, len(lod.positions)))
		return
	}
	lod.num_vertices = num_vertices
	lod.positions = lod.positions[:int(num_vertices)]
	if len(lod.uvs) >= int(num_vertices) {
		lod.uvs = lod.uvs[:int(num_vertices)]
	}

	// Index buffer: FRawStaticIndexBuffer stores 16-bit indices in a resource
	// array, so the element size is always 2 at this version.
	i_element_size, index_count, i_ok := read_bulk_header(r)
	if r.failed || !i_ok || i_element_size != 2 {
		diag.err(&d, "ue3.static-mesh-indices", "unexpected index buffer layout")
		return
	}
	if index_count % 3 != 0 {
		diag.err(&d, "ue3.static-mesh-indices", fmt.aprintf("index count %d is not a multiple of 3", index_count))
		return
	}
	if !need(r, int(index_count) * 2) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	lod.indices = make([]u16, int(index_count), allocator)
	for i in 0..<int(index_count) {
		lod.indices[i] = read_u16(r)
	}
	for index, i in lod.indices {
		if int(index) >= len(lod.positions) {
			diag.err(&d, "ue3.static-mesh-indices", fmt.aprintf("index %d references vertex %d of %d", i, index, len(lod.positions)))
			return
		}
	}

	// Wireframe index buffer, legacy edges and legacy double-sided flags.
	_ = skip_bulk(r)
	_ = skip_bulk(r)
	shadow_count := read_i32(r)
	if r.failed || shadow_count < 0 || !need(r, int(shadow_count)) {
		diag.err(&d, "ue3.static-mesh-shadow", "implausible legacy shadow triangle count")
		return
	}
	r.pos += int(shadow_count)

	if version >= VER_CRACK_FREE_DISPLACEMENT_SUPPORT {
		_ = skip_bulk(r) // adjacency index buffer
	}
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
	}
	return
}

// half_to_f32 decodes an IEEE 754 binary16 value, the storage used by the
// legacy UV sets.
half_to_f32 :: proc(bits: u16) -> f32 {
	return f32(transmute(f16)bits)
}

// static_mesh_destroy releases the slices of a parsed mesh.
static_mesh_destroy :: proc(mesh: ^Static_Mesh) {
	for &lod in mesh.lods {
		delete(lod.positions)
		delete(lod.indices)
		delete(lod.uvs)
		delete(lod.sections)
	}
	delete(mesh.lods)
	mesh.lods = nil
}

to_geom :: proc(v: Vec3) -> geom.Vec3 { return geom.Vec3{f64(v.x), f64(v.y), f64(v.z)} }
to_ue :: proc(v: geom.Vec3) -> Vec3 { return Vec3{f32(v.x), f32(v.y), f32(v.z)} }

// static_mesh_obj renders one LOD as Wavefront OBJ in Unreal coordinates
// (X forward, Y right, Z up). Indices are emitted one-based as OBJ requires.
static_mesh_obj :: proc(mesh: ^Static_Mesh, lod_index: int, t: xform.Transform) -> string {
	if lod_index < 0 || lod_index >= len(mesh.lods) {
		return ""
	}
	lod := mesh.lods[lod_index]
	b := strings.builder_make()
	fmt.sbprintf(&b, "# %s LOD %d\n", mesh.name, lod_index)
	fmt.sbprintf(&b, "# vertices %d, triangles %d\n", len(lod.positions), len(lod.indices) / 3)
	fmt.sbprintf(&b, "o %s_L%d\n", mesh.name, lod_index)
	for position in lod.positions {
		p := to_ue(xform.apply_point(t, to_geom(position)))
		fmt.sbprintf(&b, "v %.6f %.6f %.6f\n", p.x, p.y, p.z)
	}
	has_uv := len(lod.uvs) == len(lod.positions)
	if has_uv {
		for uv in lod.uvs {
			fmt.sbprintf(&b, "vt %.6f %.6f\n", uv.x, 1 - uv.y)
		}
	}
	for i := 0; i + 2 < len(lod.indices); i += 3 {
		a := lod.indices[i] + 1
		bb := lod.indices[i + 1] + 1
		c := lod.indices[i + 2] + 1
		if has_uv {
			fmt.sbprintf(&b, "f %d/%d %d/%d %d/%d\n", a, a, bb, bb, c, c)
		} else {
			fmt.sbprintf(&b, "f %d %d %d\n", a, bb, c)
		}
	}
	return strings.to_string(b)
}

// vec3_sub/cross/normalize are local to keep the mesh writer dependency-free.
vec3_sub :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return Vec3 {
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x,
	}
}

vec3_normalize :: proc(v: Vec3) -> Vec3 {
	length := v.x * v.x + v.y * v.y + v.z * v.z
	if length <= 0 {
		return Vec3{0, 0, 1}
	}
	inv := 1 / sqrt_f32(length)
	return Vec3{v.x * inv, v.y * inv, v.z * inv}
}

sqrt_f32 :: proc(v: f32) -> f32 {
	// Newton iteration is enough for shading normals and avoids pulling in math.
	x := v
	if x <= 0 {
		return 0
	}
	for _ in 0..<12 {
		x = 0.5 * (x + v / x)
	}
	return x
}

// static_mesh_smd renders one LOD as a StudioMDL reference mesh: one material
// per section, flat face normals and UV set 0.
static_mesh_smd :: proc(mesh: ^Static_Mesh, lod_index: int, t: xform.Transform) -> string {
	if lod_index < 0 || lod_index >= len(mesh.lods) {
		return ""
	}
	lod := mesh.lods[lod_index]
	b := strings.builder_make()
	strings.write_string(&b, "version 1\nnodes\n0 \"static\" -1\nend\nskeleton\ntime 0\n0 0 0 0 0 0 0\nend\ntriangles\n")
	has_uv := len(lod.uvs) >= len(lod.positions)
	for i := 0; i + 2 < len(lod.indices); i += 3 {
		a := int(lod.indices[i])
		bb := int(lod.indices[i + 1])
		c := int(lod.indices[i + 2])
		// SMD material names are relative to $cdmaterials, so a name that
		// already carries a package path would be looked up twice.
		material := "unknown"
		for section in lod.sections {
			if i >= int(section.first_index) && i < int(section.first_index) + int(section.num_triangles) * 3 {
				name := section.material_name
				if idx := strings.last_index_byte(name, '/'); idx >= 0 {
					name = name[idx + 1:]
				}
				if name != "" {
					material = name
				}
				break
			}
		}
		p0 := to_ue(xform.apply_point(t, to_geom(lod.positions[a])))
		p1 := to_ue(xform.apply_point(t, to_geom(lod.positions[bb])))
		p2 := to_ue(xform.apply_point(t, to_geom(lod.positions[c])))
		n := vec3_normalize(vec3_cross(vec3_sub(p1, p0), vec3_sub(p2, p0)))
		fmt.sbprintf(&b, "%s\n", material)
		for vertex in ([]int{a, bb, c}) {
			p := to_ue(xform.apply_point(t, to_geom(lod.positions[vertex])))
			uv := Vec2{0, 0}
			if has_uv {
				uv = lod.uvs[vertex]
			}
			fmt.sbprintf(
				&b,
				"0 %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f\n",
				p.x, p.y, p.z, n.x, n.y, n.z, uv.x, 1 - uv.y,
			)
		}
	}
	strings.write_string(&b, "end\n")
	return strings.to_string(b)
}

// static_mesh_qc writes a compile-ready QC: the model name is the .mdl the VMF
// should reference after studiomdl runs, and the body points at the LOD 0 SMD.
static_mesh_qc :: proc(model_name, smd_name, materials_dir: string) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "$modelname \"%s\"\n", model_name)
	fmt.sbprintf(&b, "$body \"body\" \"%s\"\n", smd_name)
	fmt.sbprintf(&b, "$cdmaterials \"%s\"\n", materials_dir)
	strings.write_string(&b, "$surfaceprop \"default\"\n$staticprop\n")
	fmt.sbprintf(&b, "$sequence \"idle\" \"%s\" fps 30\n", smd_name)
	return strings.to_string(b)
}
