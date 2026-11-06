package ue3

import "core:strings"
import "core:testing"
import "../diag"

// Synthetic StaticMesh package: one LOD with three positions and one triangle.
// The layout follows the 576 legacy path documented in static_mesh.odin; the
// real packages (EngineMeshes, city01) are checked by the CLI tests.

build_static_mesh_payload :: proc(payload_offset: int) -> [dynamic]u8 {
	// Name indices as laid out by build_static_mesh_package.
	NAME_BODYSETUP :: 5
	NAME_OBJECTPROPERTY :: 6

	p := Builder{}
	put_i32(&p, 0) // NetIndex
	put_tag_header(&p, NAME_BODYSETUP, NAME_OBJECTPROPERTY, 4, 0)
	put_i32(&p, 0) // BodySetup = null
	put_i32(&p, 0) // None
	put_i32(&p, 0)

	// Bounds: origin (0,0,0), extent (10,10,10), sphere radius.
	put_f32(&p, 0); put_f32(&p, 0); put_f32(&p, 0)
	put_f32(&p, 10); put_f32(&p, 10); put_f32(&p, 10)
	put_f32(&p, 17.320508)
	put_i32(&p, 0) // BodySetup reference

	// Legacy kDOP tree: no nodes, no triangles.
	put_bulk_header(&p, 32, 0)
	put_bulk_header(&p, 8, 0)
	put_i32(&p, 18) // InternalVersion
	put_i32(&p, 0) // legacy content tags
	put_i32(&p, 1) // one LOD

	// RawTriangles: empty, stored inline.
	put_i32(&p, 0) // flags
	put_i32(&p, 0) // count
	put_i32(&p, 0) // size on disk
	put_i32(&p, i32(payload_offset + len(p.buf) + 4)) // offset

	// One element covering the only triangle.
	put_i32(&p, 1) // element count
	put_i32(&p, 0) // material
	put_i32(&p, 1) // EnableCollision
	put_i32(&p, 1) // OldEnableCollision
	put_i32(&p, 1) // bEnableShadowCasting
	put_i32(&p, 0) // FirstIndex
	put_i32(&p, 1) // NumTriangles
	put_i32(&p, 0) // MinVertexIndex
	put_i32(&p, 2) // MaxVertexIndex
	put_i32(&p, 0) // MaterialIndex
	put_i32(&p, 0) // fragment count

	// Position buffer: three Vec3.
	put_i32(&p, 12) // stride
	put_i32(&p, 3) // NumVertices
	put_bulk_header(&p, 12, 3)
	put_f32(&p, 0); put_f32(&p, 0); put_f32(&p, 0)
	put_f32(&p, 10); put_f32(&p, 0); put_f32(&p, 0)
	put_f32(&p, 0); put_f32(&p, 10); put_f32(&p, 0)

	// Legacy interleaved vertex buffer: two UV sets, 20-byte stride. Tangents
	// and color are zero; UV0 is (0.25, 0.5) for every vertex.
	put_i32(&p, 2) // NumTexCoords
	put_i32(&p, 20) // stride
	put_i32(&p, 3) // count
	put_i32(&p, 0) // bUseFullPrecisionUVs
	put_bulk_header(&p, 20, 3)
	for _ in 0..<3 {
		for _ in 0..<12 {
			append(&p.buf, 0)
		}
		put_half(&p, 0.25)
		put_half(&p, 0.5)
		put_half(&p, 0)
		put_half(&p, 0)
	}

	// Legacy shadow extrusion buffer.
	put_i32(&p, 4)
	put_i32(&p, 3)
	put_bulk_header(&p, 4, 3)
	for _ in 0..<12 {
		append(&p.buf, 0)
	}

	put_i32(&p, 3) // NumVertices (no shadow clones here)
	put_bulk_header(&p, 2, 3) // index buffer
	append(&p.buf, 0, 0) // 0
	append(&p.buf, 1, 0) // 1
	append(&p.buf, 2, 0) // 2
	put_bulk_header(&p, 2, 0) // wireframe
	put_bulk_header(&p, 16, 0) // legacy edges
	put_i32(&p, 0) // legacy shadow double-sided flags
	return p.buf
}

build_static_mesh_package :: proc() -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "StaticMesh", "BodySetup", "ObjectProperty", "TestMesh"}) {
		put_name_entry(&nb, text, 0)
	}
	names_buf = nb.buf

	imports_buf: [dynamic]u8
	ib := Builder{buf = imports_buf}
	put_name_ref(&ib, 2, 0) // class package = Package
	put_name_ref(&ib, 1, 0) // class name = Class
	put_i32(&ib, 0) // outer = null
	put_name_ref(&ib, 3, 0) // object name = Engine
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1) // outer = import 0 (Engine)
	put_name_ref(&ib, 4, 0) // object name = StaticMesh
	imports_buf = ib.buf

	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(names_buf)
	export_offset := import_offset + len(imports_buf)
	payload_offset := export_offset + 68
	payload := build_static_mesh_payload(payload_offset)
	depends_offset := payload_offset + len(payload)

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	put_i32(&eb, -2) // class = import 1 (StaticMesh)
	put_i32(&eb, 0)
	put_i32(&eb, 0) // top level
	put_name_ref(&eb, 7, 0) // TestMesh
	put_i32(&eb, 0)
	put_u64(&eb, 0) // no RF_HasStack
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
	put_i32(&h, 8) // name count
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1) // export count
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2) // import count
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 1)
	put_i32(&h, 8)
	put_i32(&h, 0)
	put_i32(&h, 4701)
	put_i32(&h, 87)
	put_u32(&h, 0) // compression flags
	put_i32(&h, 0) // chunks
	put_i32(&h, 0) // package source
	put_i32(&h, 0) // additional packages
	append(&h.buf, ..names_buf[:])
	append(&h.buf, ..imports_buf[:])
	append(&h.buf, ..exports_buf[:])
	append(&h.buf, ..payload[:])
	return h.buf
}

@(test)
test_read_static_mesh :: proc(t: ^testing.T) {
	data := build_static_mesh_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	testing.expect_value(t, len(pkg.exports), 1)
	testing.expect(t, export_is_static_mesh(&pkg, pkg.exports[0]))

	mesh, mesh_d := read_static_mesh(&pkg, 0)
	defer delete(mesh_d.items)
	testing.expect_value(t, diag.count(&mesh_d, .Error), 0)
	testing.expect_value(t, len(mesh.lods), 1)
	lod := mesh.lods[0]
	testing.expect_value(t, len(lod.positions), 3)
	testing.expect_value(t, len(lod.indices), 3)
	testing.expect_value(t, len(lod.sections), 1)
	testing.expect_value(t, lod.sections[0].num_triangles, i32(1))
	testing.expect_value(t, lod.positions[1].x, f32(10))
	testing.expect_value(t, lod.indices[2], u16(2))
	testing.expect_value(t, len(lod.uvs), 3)
	testing.expect(t, abs(lod.uvs[0].x - 0.25) < 0.001)
	testing.expect(t, abs(lod.uvs[0].y - 0.5) < 0.001)
	// The test mesh has no material reference, so the name stays empty.
	testing.expect_value(t, lod.sections[0].material_name, "")

	obj := static_mesh_obj(&mesh, 0)
	defer delete(obj)
	testing.expect(t, strings.contains(obj, "f 1/1 2/2 3/3"))
	static_mesh_destroy(&mesh)
}

put_half :: proc(b: ^Builder, v: f32) {
	bits := transmute(u16)(f16(v))
	append(&b.buf, u8(bits), u8(bits >> 8))
}

@(test)
test_import_package :: proc(t: ^testing.T) {
	data := build_static_mesh_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	// The mesh import's outer chain ends at the Engine package.
	package_name, object_name := import_package(&pkg, -2)
	testing.expect_value(t, package_name, "Engine")
	testing.expect_value(t, object_name, "StaticMesh")
	testing.expect_value(t, ascii_lower("EngineMeshes"), "enginemeshes")
}
