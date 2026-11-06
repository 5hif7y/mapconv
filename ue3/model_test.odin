package ue3

import "core:strings"
import "core:testing"
import "../diag"

// Synthetic UModel package: one level model with one quad node, one surface and
// four vertices. The byte layout follows UModel::Serialize as verified against
// real level models (see docs/formats/ue3-package.md).

put_bulk_header :: proc(b: ^Builder, element_size, count: i32) {
	put_i32(b, element_size)
	put_i32(b, count)
}

put_plane4 :: proc(b: ^Builder, nx, ny, nz, dist: f32) {
	put_f32(b, nx)
	put_f32(b, ny)
	put_f32(b, nz)
	put_f32(b, dist)
}

build_model_payload :: proc() -> [dynamic]u8 {
	p := Builder{}
	put_i32(&p, 1) // NetIndex
	put_i32(&p, 0) // "None" tag
	put_i32(&p, 0)

	// Bounds: origin, box extent, sphere radius.
	put_vec3(&p, 32, 32, 0)
	put_vec3(&p, 32, 32, 0)
	put_f32(&p, 45.25)

	// Vectors: normal, U, V and a spare.
	put_bulk_header(&p, 12, 4)
	put_vec3(&p, 0, 0, 1)
	put_vec3(&p, 1, 0, 0)
	put_vec3(&p, 0, 1, 0)
	put_vec3(&p, 0, 0, -1)

	// Points: the quad.
	put_bulk_header(&p, 12, 4)
	put_vec3(&p, 0, 0, 0)
	put_vec3(&p, 64, 0, 0)
	put_vec3(&p, 64, 64, 0)
	put_vec3(&p, 0, 64, 0)

	// Nodes: one quad node on z=0.
	put_bulk_header(&p, 64, 1)
	put_plane4(&p, 0, 0, 1, 0)
	put_i32(&p, 0) // iVertPool
	put_i32(&p, 0) // iSurf
	put_i32(&p, 0) // iVertexIndex
	put_u32(&p, 0) // ComponentIndex + ComponentNodeIndex (two WORDs)
	put_i32(&p, 0) // ComponentElementIndex
	put_i32(&p, -1) // iBack
	put_i32(&p, -1) // iFront
	put_i32(&p, -1) // iPlane
	put_i32(&p, -1) // iCollisionBound
	put_u32(&p, 0x00040000) // iZone[0]=0, iZone[1]=0, NumVertices=4, NodeFlags=0
	put_i32(&p, -1) // iLeaf[0]
	put_i32(&p, -1) // iLeaf[1]

	// Surfs: TTransArray writes the owner first.
	put_i32(&p, 1) // owner = package index 1 (this export)
	put_i32(&p, 1) // count
	put_i32(&p, 0) // Material
	put_u32(&p, 1) // PolyFlags
	put_i32(&p, 0) // pBase
	put_i32(&p, 0) // vNormal
	put_i32(&p, 1) // vTextureU
	put_i32(&p, 2) // vTextureV
	put_i32(&p, 0) // iBrushPoly
	put_i32(&p, 0) // Actor
	put_plane4(&p, 0, 0, 1, 0)
	put_f32(&p, 1) // ShadowMapScale
	put_u32(&p, 1) // LightingChannels

	// Verts: 24-byte records.
	put_bulk_header(&p, 24, 4)
	for i in 0..<4 {
		put_i32(&p, i32(i)) // pVertex
		put_i32(&p, -1) // iSide
		put_f32(&p, 0) // ShadowTexCoord
		put_f32(&p, 0)
		put_f32(&p, 0) // BackfaceShadowTexCoord
		put_f32(&p, 0)
	}

	put_i32(&p, 0) // NumSharedSides
	put_i32(&p, 0) // NumZones
	put_i32(&p, 0) // Polys reference
	put_bulk_header(&p, 4, 0) // LeafHulls
	put_bulk_header(&p, 4, 0) // Leaves
	put_i32(&p, 1) // RootOutside
	put_i32(&p, 0) // Linked
	put_bulk_header(&p, 4, 0) // PortalNodes
	put_bulk_header(&p, 16, 0) // LegacyEdges (version < 686)
	put_i32(&p, 4) // NumUniqueVertices
	put_bulk_header(&p, 36, 0) // VertexBuffer
	return p.buf
}

build_single_model_package :: proc(payload: []u8) -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "Model", "Model_0"}) {
		put_name_entry(&nb, text, 0)
	}
	names_buf = nb.buf

	imports_buf: [dynamic]u8
	ib := Builder{buf = imports_buf}
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, 0)
	put_name_ref(&ib, 3, 0)
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1)
	put_name_ref(&ib, 4, 0)
	imports_buf = ib.buf

	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(names_buf)
	export_offset := import_offset + len(imports_buf)
	payload_offset := export_offset + 68
	depends_offset := payload_offset + len(payload)

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	put_i32(&eb, -2) // class = import 1 (Model)
	put_i32(&eb, 0)
	put_i32(&eb, 0)
	put_name_ref(&eb, 5, 0)
	put_i32(&eb, 0)
	put_u64(&eb, 0)
	put_i32(&eb, i32(len(payload)))
	put_i32(&eb, i32(payload_offset))
	put_u32(&eb, 0)
	put_i32(&eb, 0)
	put_guid(&eb)
	put_u32(&eb, 0)
	exports_buf = eb.buf

	out: [dynamic]u8
	h := Builder{buf = out}
	put_u32(&h, PACKAGE_FILE_TAG)
	put_u32(&h, 0x00050240)
	put_i32(&h, i32(header_fixed))
	put_fstring(&h, "")
	put_u32(&h, PKG_COOKED)
	put_i32(&h, 6)
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1)
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2)
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 1)
	put_i32(&h, 6)
	put_i32(&h, 0)
	put_i32(&h, 4701)
	put_i32(&h, 87)
	put_u32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	append(&h.buf, ..names_buf[:])
	append(&h.buf, ..imports_buf[:])
	append(&h.buf, ..exports_buf[:])
	append(&h.buf, ..payload)
	return h.buf
}

@(test)
test_read_model_single_quad :: proc(t: ^testing.T) {
	payload := build_model_payload()
	data := build_single_model_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	testing.expect_value(t, len(pkg.exports), 1)

	model, m_diags := read_model(&pkg, 0)
	defer delete(m_diags.items)
	testing.expect_value(t, diag.count(&m_diags, .Error), 0)
	testing.expect_value(t, diag.count(&m_diags, .Warning), 0)
	testing.expect_value(t, len(model.nodes), 1)
	testing.expect_value(t, len(model.surfs), 1)
	testing.expect_value(t, len(model.verts), 4)
	testing.expect_value(t, len(model.points), 4)
	testing.expect_value(t, model.surf_owner, i32(1))
	testing.expect_value(t, model.nodes[0].num_vertices, u8(4))
	testing.expect_value(t, model.nodes[0].plane.normal.z, f32(1))
	testing.expect_value(t, model.surfs[0].poly_flags, u32(1))

	polygons := model_polygons(&model)
	testing.expect_value(t, len(polygons), 1)
	if len(polygons) == 1 {
		testing.expect_value(t, len(polygons[0].vertices), 4)
		testing.expect_value(t, polygons[0].vertices[2].x, f32(64))
		testing.expect_value(t, polygons[0].vertices[2].y, f32(64))
		testing.expect_value(t, polygons[0].material, i32(0))
		testing.expect_value(t, polygons[0].plane.dist, f32(0))
	}
}

@(test)
test_inspect_reports_bsp_models :: proc(t: ^testing.T) {
	payload := build_model_payload()
	data := build_single_model_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	text := inspect_text(&pkg, "model.ccmap")
	defer delete(text)
	testing.expect(t, strings.contains(text, "bsp models:"))
	testing.expect(t, strings.contains(text, "1 model(s)"))
	testing.expect(t, strings.contains(text, "1 polygon(s)"))
}

@(test)
test_model_size_mismatch_is_reported :: proc(t: ^testing.T) {
	payload := build_model_payload()
	data := build_single_model_package(payload[:])
	// Keep the claimed range inside the file: the export is the last object.
	append(&data, 0, 0, 0, 0)
	pkg, d := parse(data[:])
	defer delete(d.items)
	pkg.exports[0].serial_size += 4
	_, m_diags := read_model(&pkg, 0)
	defer delete(m_diags.items)
	testing.expect_value(t, diag.count(&m_diags, .Warning), 1)
}

@(test)
test_model_rejects_bad_bulk_sizes :: proc(t: ^testing.T) {
	payload := build_model_payload()
	// Corrupt the Vectors element size (first bulk header after the 28-byte
	// bounds and the 12-byte object prelude).
	payload[12 + 28] = 16
	data := build_single_model_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	_, m_diags := read_model(&pkg, 0)
	defer delete(m_diags.items)
	testing.expect_value(t, diag.count(&m_diags, .Error), 1)
}

@(test)
test_model_solids_follow_pointcheck_rule :: proc(t: ^testing.T) {
	// One CSG node with RootOutside: the front leaf is outside, the back leaf is
	// solid and bounded by the node plane as stored (brush convention).
	payload := build_model_payload()
	data := build_single_model_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	model, m_diags := read_model(&pkg, 0)
	defer delete(m_diags.items)
	solids := model_solids(&model)
	testing.expect_value(t, len(solids), 1)
	if len(solids) == 1 {
		testing.expect_value(t, len(solids[0].planes), 1)
		testing.expect_value(t, solids[0].planes[0].plane.normal.z, f32(1))
		testing.expect_value(t, solids[0].planes[0].plane.dist, f32(0))
		testing.expect_value(t, solids[0].planes[0].node_index, 0)
	}
}

@(test)
test_model_solids_ignore_non_csg_nodes :: proc(t: ^testing.T) {
	// NF_NotCsg (0x01) makes the node transparent: it does not turn the back
	// leaf solid, so no region is produced.
	payload := build_model_payload()
	// 12 prelude + 28 bounds + (8 + 4*12) Vectors + (8 + 4*12) Points + 8 nodes
	// header + 55 bytes into the node record.
	flags_offset := 12 + 28 + (8 + 4 * 12) + (8 + 4 * 12) + 8 + 55
	payload[flags_offset] = 0x01
	data := build_single_model_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	model, m_diags := read_model(&pkg, 0)
	defer delete(m_diags.items)
	testing.expect_value(t, model.nodes[0].flags, u8(0x01))
	testing.expect_value(t, len(model_solids(&model)), 0)
}
