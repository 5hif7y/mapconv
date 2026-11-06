package ue3

import "core:math"
import "core:strings"
import "core:testing"
import "../diag"
import "../geom"

// The object-level tests reuse the byte builder from ue3_test.odin and add two
// export payloads after the depends table:
//
//	export 0: a UPolys with one quad polygon (a 64-unit square on z=0)
//	export 1: an object with one BoolProperty tag named bTest followed by body
//
// The package layout is still the verified 576/5 one, so the same table-bound
// checks apply.

put_f32 :: proc(b: ^Builder, v: f32) {
	put_u32(b, transmute(u32)v)
}

put_vec3 :: proc(b: ^Builder, x: f32, y: f32, z: f32) {
	put_f32(b, x)
	put_f32(b, y)
	put_f32(b, z)
}

build_polys_payload :: proc() -> [dynamic]u8 {
	p := Builder{}
	put_i32(&p, 7) // NetIndex
	put_i32(&p, 0) // "None" tag: name
	put_i32(&p, 0) //             number
	put_i32(&p, 1) // Num
	put_i32(&p, 1) // Max
	put_i32(&p, 1) // Owner: package index 1 = export 0 (self)
	// One quad.
	put_vec3(&p, 1, 2, 3) // Base
	put_vec3(&p, 0, 0, 1) // Normal
	put_vec3(&p, 1, 0, 0) // TextureU
	put_vec3(&p, 0, 1, 0) // TextureV
	put_i32(&p, 4) // vertices
	put_vec3(&p, 0, 0, 0)
	put_vec3(&p, 64, 0, 0)
	put_vec3(&p, 64, 64, 0)
	put_vec3(&p, 0, 64, 0)
	put_u32(&p, 1) // PolyFlags
	put_i32(&p, 0) // Actor
	put_i32(&p, 0) // ItemName name
	put_i32(&p, 0) // ItemName number
	put_i32(&p, 0) // Material
	put_i32(&p, -1) // iLink
	put_i32(&p, 0) // iBrushPoly
	put_f32(&p, 1.0) // ShadowMapScale
	put_u32(&p, 1) // LightingChannels
	return p.buf
}

build_tag_payload :: proc() -> [dynamic]u8 {
	p := Builder{}
	put_i32(&p, 8) // NetIndex
	put_i32(&p, 7) // tag name index: bTest
	put_i32(&p, 0)
	put_i32(&p, 6) // tag type index: BoolProperty
	put_i32(&p, 0)
	put_i32(&p, 0) // Size
	put_i32(&p, 0) // ArrayIndex
	put_i32(&p, 1) // UBOOL value (version 576: 4 bytes)
	put_i32(&p, 0) // "None" name
	put_i32(&p, 0) // "None" number
	put_u32(&p, 0xDEADBEEF) // body
	return p.buf
}

build_object_package :: proc() -> [dynamic]u8 {
	// Name table indices used below.
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "Polys", "Polys_0", "BoolProperty", "bTest", "Thing"}) {
		put_name_entry(&nb, text, 0)
	}
	name_count := 9

	imports_buf: [dynamic]u8
	ib := Builder{buf = imports_buf}
	// 0: the Engine package.
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, 0)
	put_name_ref(&ib, 3, 0)
	// 1: the Polys class.
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1)
	put_name_ref(&ib, 4, 0)
	// 2: the Thing class, so the tagged export is not counted as a brush.
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1)
	put_name_ref(&ib, 8, 0)

	payload0 := build_polys_payload()
	payload1 := build_tag_payload()

	// Header fixed part with no additional packages: tag, version, header size,
	// folder "", flags, 7 counts/offsets, guid, generation count and one
	// generation, engine, cooked, compression flags, chunk count, source,
	// additional package count.
	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(nb.buf)
	export_offset := import_offset + len(ib.buf)
	payload_offset := export_offset + 2 * 68
	depends_offset := payload_offset
	_ = name_count

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	for payload, i in ([][]u8{payload0[:], payload1[:]}) {
		class_index: i32 = -2 // import 1 (Polys)
		if i == 1 {
			class_index = -3 // import 2 (Thing)
		}
		put_i32(&eb, class_index)
		put_i32(&eb, 0) // super
		put_i32(&eb, 0) // outer
		put_name_ref(&eb, 5 + i32(i), 0) // Polys_0, Thing
		put_i32(&eb, 0) // archetype
		put_u64(&eb, 0) // object flags
		put_i32(&eb, i32(len(payload))) // serial size
		offset := payload_offset
		if i == 1 {
			offset += len(payload0)
		}
		put_i32(&eb, i32(offset)) // serial offset
		put_u32(&eb, 0) // export flags
		put_i32(&eb, 0) // generation net object count
		put_guid(&eb)
		put_u32(&eb, 0) // package flags
	}

	out: [dynamic]u8
	h := Builder{buf = out}
	put_u32(&h, PACKAGE_FILE_TAG)
	put_u32(&h, 0x00050240)
	put_i32(&h, i32(header_fixed))
	put_fstring(&h, "")
	put_u32(&h, PKG_COOKED | PKG_CONTAINS_MAP)
	put_i32(&h, i32(name_count))
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 2) // export count
	put_i32(&h, i32(export_offset))
	put_i32(&h, 3) // import count
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 2)
	put_i32(&h, i32(name_count))
	put_i32(&h, 4)
	put_i32(&h, 4701)
	put_i32(&h, 87)
	put_u32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0) // additional package count
	append(&h.buf, ..nb.buf[:])
	append(&h.buf, ..ib.buf[:])
	append(&h.buf, ..eb.buf[:])
	append(&h.buf, ..payload0[:])
	append(&h.buf, ..payload1[:])
	return h.buf
}

@(test)
test_object_head_reads_property_tags :: proc(t: ^testing.T) {
	data := build_object_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	testing.expect_value(t, len(pkg.exports), 2)

	head, head_d := read_object_head(&pkg, pkg.exports[1])
	defer delete(head_d.items)
	testing.expect_value(t, diag.count(&head_d, .Error), 0)
	testing.expect_value(t, head.net_index, i32(8))
	testing.expect_value(t, len(head.tags), 1)
	testing.expect_value(t, name_text(&pkg, head.tags[0].name), "bTest")
	testing.expect_value(t, name_text(&pkg, head.tags[0].type), "BoolProperty")
	testing.expect_value(t, head.tags[0].bool_value, u8(1))
	testing.expect_value(t, head.tags[0].size, i32(0))
	// NetIndex(4) + tag(24) + bool value(4) + None(8).
	testing.expect_value(t, head.body_offset, int(pkg.exports[1].serial_offset) + 40)
	testing.expect_value(t, head.end_offset, int(pkg.exports[1].serial_offset) + int(pkg.exports[1].serial_size))
}

@(test)
test_read_polys_quad :: proc(t: ^testing.T) {
	data := build_object_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	set, set_d := read_polys(&pkg, 0)
	defer delete(set_d.items)
	testing.expect_value(t, diag.count(&set_d, .Error), 0)
	testing.expect_value(t, diag.count(&set_d, .Warning), 0)
	testing.expect_value(t, len(set.polygons), 1)
	testing.expect_value(t, set.vertices, 4)
	testing.expect_value(t, set.owner_index, i32(1))
	testing.expect_value(t, set.max_elements, i32(1))
	poly := set.polygons[0]
	testing.expect_value(t, poly.base.x, f32(1))
	testing.expect_value(t, poly.base.y, f32(2))
	testing.expect_value(t, poly.normal.z, f32(1))
	testing.expect_value(t, len(poly.vertices), 4)
	testing.expect_value(t, poly.vertices[2].x, f32(64))
	testing.expect_value(t, poly.vertices[2].y, f32(64))
	testing.expect_value(t, poly.poly_flags, u32(1))
	testing.expect_value(t, poly.i_link, i32(-1))
	testing.expect_value(t, poly.shadow_map_scale, f32(1))
}

@(test)
test_inspect_reports_brush_polys :: proc(t: ^testing.T) {
	data := build_object_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	text := inspect_text(&pkg, "synthetic.ccmap")
	defer delete(text)
	testing.expect(t, strings.contains(text, "brush polys:"))
	testing.expect(t, strings.contains(text, "1 UPolys object(s), 1 polygon(s), 4 vertex/vertices"))
}

@(test)
test_truncated_polys_payload_reports_error :: proc(t: ^testing.T) {
	data := build_object_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	// Shrink the export so the polygon does not fit.
	pkg.exports[0].serial_size = 40
	_, set_d := read_polys(&pkg, 0)
	defer delete(set_d.items)
	testing.expect_value(t, diag.count(&set_d, .Error), 1)
}

@(test)
test_polys_size_mismatch_is_reported :: proc(t: ^testing.T) {
	data := build_object_package()
	pkg, d := parse(data[:])
	defer delete(d.items)
	// Claim four extra bytes: the parse still works but does not consume the
	// payload, which is the signature of a wrong FPoly layout.
	pkg.exports[0].serial_size += 4
	_, set_d := read_polys(&pkg, 0)
	defer delete(set_d.items)
	testing.expect_value(t, diag.count(&set_d, .Warning), 1)
}

// build_single_polys_package wraps one UPolys payload in a minimal 576/5 package
// with a single export of class Polys, so the importer can be tested end to end.
build_single_polys_package :: proc(payload: []u8) -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "Polys", "Polys_0"}) {
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
	put_i32(&eb, -2) // class = import 1 (Polys)
	put_i32(&eb, 0)
	put_i32(&eb, 0)
	put_name_ref(&eb, 5, 0) // Polys_0
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
	put_i32(&h, 6) // names
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1) // exports
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2) // imports
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
	put_i32(&h, 0) // additional packages
	append(&h.buf, ..names_buf[:])
	append(&h.buf, ..imports_buf[:])
	append(&h.buf, ..exports_buf[:])
	append(&h.buf, ..payload)
	return h.buf
}

put_poly :: proc(b: ^Builder, verts: []Vec3, normal, u, v: Vec3) {
	// Base is stored in brush-local space; the importer must not use it.
	put_vec3(b, 0, 0, 0)
	put_vec3(b, normal.x, normal.y, normal.z)
	put_vec3(b, u.x, u.y, u.z)
	put_vec3(b, v.x, v.y, v.z)
	put_i32(b, i32(len(verts)))
	for vert in verts {
		put_vec3(b, vert.x, vert.y, vert.z)
	}
	put_u32(b, 1) // PolyFlags
	put_i32(b, 0) // Actor
	put_i32(b, 0) // ItemName
	put_i32(b, 0)
	put_i32(b, 0) // Material
	put_i32(b, -1) // iLink
	put_i32(b, 0) // iBrushPoly
	put_f32(b, 1) // ShadowMapScale
	put_u32(b, 1) // LightingChannels
}

build_cube_payload :: proc() -> [dynamic]u8 {
	p := Builder{}
	put_i32(&p, 3) // NetIndex
	put_i32(&p, 0) // "None"
	put_i32(&p, 0)
	put_i32(&p, 6) // Num
	put_i32(&p, 6) // Max
	put_i32(&p, 1) // Owner = self

	u := Vec3{1, 0, 0}
	v := Vec3{0, 1, 0}
	put_poly(&p, []Vec3{{32, -32, -32}, {32, 32, -32}, {32, 32, 32}, {32, -32, 32}}, Vec3{1, 0, 0}, u, v)
	put_poly(&p, []Vec3{{-32, -32, -32}, {-32, -32, 32}, {-32, 32, 32}, {-32, 32, -32}}, Vec3{-1, 0, 0}, u, v)
	put_poly(&p, []Vec3{{-32, 32, -32}, {-32, 32, 32}, {32, 32, 32}, {32, 32, -32}}, Vec3{0, 1, 0}, u, v)
	put_poly(&p, []Vec3{{-32, -32, -32}, {32, -32, -32}, {32, -32, 32}, {-32, -32, 32}}, Vec3{0, -1, 0}, u, v)
	put_poly(&p, []Vec3{{-32, -32, 32}, {32, -32, 32}, {32, 32, 32}, {-32, 32, 32}}, Vec3{0, 0, 1}, u, v)
	put_poly(&p, []Vec3{{-32, -32, -32}, {-32, 32, -32}, {32, 32, -32}, {32, -32, -32}}, Vec3{0, 0, -1}, u, v)
	return p.buf
}

@(test)
test_import_cube_brush :: proc(t: ^testing.T) {
	payload := build_cube_payload()
	data := build_single_polys_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)

	doc, import_d := import_document(data[:], "cube.ccmap")
	defer delete(import_d.items)
	testing.expect_value(t, diag.count(&import_d, .Error), 0)
	testing.expect_value(t, len(doc.brushes), 1)
	testing.expect_value(t, len(doc.world.brushes), 1)
	testing.expect_value(t, doc.world.class_name, "worldspawn")
	brush := doc.brushes[0]
	testing.expect_value(t, len(brush.faces), 6)
	for face in brush.faces {
		testing.expect_value(t, len(face.winding), 4)
		testing.expect(t, math.abs(face.plane.dist - 32) < 1e-4)
		testing.expect_value(t, face.material, "TOOLS/NODRAW")
		testing.expect(t, face.winding_source == .Authored)
		// The plane must contain its own winding.
		for point in face.winding {
			testing.expect(t, math.abs(geom.dot(face.plane.normal, point) - face.plane.dist) < 1e-4)
		}
	}
	if len(doc.brushes) == 1 {
		_ = pkg
	}
}

@(test)
test_import_degenerate_polys_reports_error :: proc(t: ^testing.T) {
	// One triangle: not a brush, so the import must fail with a clear diagnostic.
	p := Builder{}
	put_i32(&p, 4)
	put_i32(&p, 0)
	put_i32(&p, 0)
	put_i32(&p, 1)
	put_i32(&p, 1)
	put_i32(&p, 1)
	put_poly(&p, []Vec3{{0, 0, 0}, {64, 0, 0}, {0, 64, 0}}, Vec3{0, 0, 1}, Vec3{1, 0, 0}, Vec3{0, 1, 0})
	data := build_single_polys_package(p.buf[:])
	_, d := import_document(data[:], "tri.ccmap")
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 1)
}
