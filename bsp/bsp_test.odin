package bsp

import "core:testing"
import "../diag"
import "../geom"
import "../ir"

// The tests build a minimal but structurally valid Source BSP: one brush entity
// with a cube brush made of six brush sides. World geometry is not exercised here
// because it needs a full BSP tree; it is covered by the manual runs documented in
// docs/formats/source-bsp.md.

Builder :: struct {
	data:     [dynamic]u8,
	offsets:  [64]int,
	lengths:  [64]int,
}

write_bytes :: proc(b: ^Builder, bytes: ..u8) {
	for byte in bytes {
		append(&b.data, byte)
	}
}

write_i16 :: proc(b: ^Builder, v: i16) {
	u := u16(v)
	write_bytes(b, u8(u & 0xff), u8(u >> 8))
}

write_u16 :: proc(b: ^Builder, v: u16) {
	write_i16(b, i16(v))
}

write_i32 :: proc(b: ^Builder, v: i32) {
	u := u32(v)
	write_bytes(b, u8(u & 0xff), u8((u >> 8) & 0xff), u8((u >> 16) & 0xff), u8((u >> 24) & 0xff))
}

write_f32 :: proc(b: ^Builder, v: f32) {
	write_i32(b, transmute(i32)v)
}

begin_lump :: proc(b: ^Builder, id: int) {
	b.offsets[id] = len(b.data)
	b.lengths[id] = 0
}

end_lump :: proc(b: ^Builder, id: int) {
	b.lengths[id] = len(b.data) - b.offsets[id]
}

// build_test_bsp creates the file and returns it.
build_test_bsp :: proc() -> []u8 {
	b: Builder
	b.data = make([dynamic]u8, 0, 4096)
	// Reserve the 1036-byte header.
	for _ in 0 ..< 1036 {
		append(&b.data, 0)
	}

	// Planes: a 128-unit cube, each plane outward.
	begin_lump(&b, LUMP_PLANES)
	normals := [6]geom.Vec3{{0, 0, 1}, {0, 0, -1}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}}
	for n in normals {
		write_f32(&b, f32(n.x))
		write_f32(&b, f32(n.y))
		write_f32(&b, f32(n.z))
		write_f32(&b, f32(64))
		write_i32(&b, 0)
	}
	end_lump(&b, LUMP_PLANES)

	// One texture name.
	begin_lump(&b, LUMP_TEXDATA_STRING_DATA)
	names := "DEV/DEV_TEST\x00ignored\x00"
	write_bytes(&b, ..transmute([]u8)names)
	end_lump(&b, LUMP_TEXDATA_STRING_DATA)

	begin_lump(&b, LUMP_TEXDATA_STRING_TABLE)
	write_i32(&b, 0)
	write_i32(&b, 13)
	end_lump(&b, LUMP_TEXDATA_STRING_TABLE)

	begin_lump(&b, LUMP_TEXDATA)
	write_f32(&b, 1)
	write_f32(&b, 1)
	write_f32(&b, 1)
	write_i32(&b, 0) // nameStringTableID
	write_i32(&b, 512)
	write_i32(&b, 512)
	write_i32(&b, 512)
	write_i32(&b, 512)
	end_lump(&b, LUMP_TEXDATA)

	begin_lump(&b, LUMP_TEXINFO)
	write_f32(&b, 1)
	write_f32(&b, 0)
	write_f32(&b, 0)
	write_f32(&b, 16)
	write_f32(&b, 0)
	write_f32(&b, 1)
	write_f32(&b, 0)
	write_f32(&b, 32)
	// lightmap vecs (unused here)
	for _ in 0 ..< 8 {
		write_f32(&b, 0)
	}
	write_i32(&b, 0)
	write_i32(&b, 0) // texdata
	end_lump(&b, LUMP_TEXINFO)

	// One brush with six sides.
	begin_lump(&b, LUMP_BRUSHES)
	write_i32(&b, 0) // firstside
	write_i32(&b, 6) // numsides
	write_i32(&b, CONTENTS_SOLID)
	end_lump(&b, LUMP_BRUSHES)

	begin_lump(&b, LUMP_BRUSHSIDES)
	for plane in 0 ..< 6 {
		write_u16(&b, u16(plane))
		write_i16(&b, 0) // texinfo
		write_i16(&b, -1) // dispinfo
		write_i16(&b, 0) // bevel
	}
	end_lump(&b, LUMP_BRUSHSIDES)

	// Model 0 is the world, model 1 is the brush entity's model.
	begin_lump(&b, LUMP_MODELS)
	for _ in 0 ..< 2 {
		for _ in 0 ..< 3 {
			write_f32(&b, -64)
		}
		for _ in 0 ..< 3 {
			write_f32(&b, 64)
		}
		for _ in 0 ..< 3 {
			write_f32(&b, 0)
		}
		write_i32(&b, 0) // headnode
		write_i32(&b, 0)
		write_i32(&b, 0)
	}
	end_lump(&b, LUMP_MODELS)

	begin_lump(&b, LUMP_NODES)
	write_i32(&b, 0) // planenum
	write_i32(&b, -1 - 1) // child 0 -> leaf 1
	write_i32(&b, -1 - 1) // child 1 -> leaf 1
	for _ in 0 ..< 6 {
		write_i16(&b, 0)
	}
	write_u16(&b, 0) // firstface
	write_u16(&b, 0) // numfaces
	write_i16(&b, -1) // area
	write_u16(&b, 0) // padding to the 32-byte record
	end_lump(&b, LUMP_NODES)

	begin_lump(&b, LUMP_LEAFS)
	for leaf in 0 ..< 2 {
		write_i32(&b, CONTENTS_SOLID if leaf == 1 else CONTENTS_EMPTY)
		write_i16(&b, 0) // cluster
		write_u16(&b, 0) // area/flags
		for _ in 0 ..< 6 {
			write_i16(&b, 0)
		}
		write_u16(&b, 0) // firstleafface
		write_u16(&b, 0) // numleaffaces
		write_u16(&b, 0) // firstleafbrush
		write_u16(&b, u16(0 if leaf == 0 else 1)) // numleafbrushes
		write_i16(&b, -1) // leafWaterDataID
		write_u16(&b, 0) // padding to the 32-byte record
	}
	end_lump(&b, LUMP_LEAFS)

	begin_lump(&b, LUMP_LEAFBRUSHES)
	write_u16(&b, 0)
	end_lump(&b, LUMP_LEAFBRUSHES)

	entities := `{
"classname" "worldspawn"
}
{
"classname" "func_brush"
"model" "*1"
"targetname" "test_brush"
}
`
	begin_lump(&b, LUMP_ENTITIES)
	write_bytes(&b, ..transmute([]u8)entities)
	end_lump(&b, LUMP_ENTITIES)

	// Patch the header: signature, version, lumps, map revision.
	header := []u8 {
		0x56, 0x42, 0x53, 0x50, // VBSP
		20, 0, 0, 0,
	}
	copy(b.data[0:8], header)
	for i in 0 ..< HEADER_LUMPS {
		base := 8 + i * 16
		store_i32(b.data[:], base, i32(b.offsets[i]))
		store_i32(b.data[:], base + 4, i32(b.lengths[i]))
		store_i32(b.data[:], base + 8, 0)
		store_i32(b.data[:], base + 12, 0)
	}
	return b.data[:]
}

store_i32 :: proc(data: []u8, offset: int, value: i32) {
	u := u32(value)
	data[offset] = u8(u & 0xff)
	data[offset + 1] = u8((u >> 8) & 0xff)
	data[offset + 2] = u8((u >> 16) & 0xff)
	data[offset + 3] = u8((u >> 24) & 0xff)
}

@(test)
test_read_minimal_bsp :: proc(t: ^testing.T) {
	data := build_test_bsp()
	diagnostics := diag.init()
	file, err := read(data, &diagnostics, "test.bsp")
	testing.expect_value(t, err, Read_Error.None)
	testing.expect_value(t, file.version, 20)
	testing.expect_value(t, len(file.planes), 6)
	testing.expect_value(t, len(file.brushes), 1)
	testing.expect_value(t, len(file.brushsides), 6)
	testing.expect_value(t, len(file.leafs), 2)
	testing.expect_value(t, len(file.texdata), 1)
	testing.expect_value(t, file.texdata[0].name, "DEV/DEV_TEST")
}

@(test)
test_rejects_non_bsp :: proc(t: ^testing.T) {
	data := make([]u8, 2048)
	diagnostics := diag.init()
	_, err := read(data, &diagnostics, "notbsp.bsp")
	testing.expect_value(t, err, Read_Error.Bad_Ident)
	testing.expect(t, diag.has_errors(&diagnostics))
}

@(test)
test_import_entity_brush :: proc(t: ^testing.T) {
	data := build_test_bsp()
	doc, diagnostics := import_document(data, "test.bsp")
	for item in diagnostics.items {
		testing.expectf(t, item.severity != .Error, "unexpected error: %s", diag.format(item))
	}
	testing.expect_value(t, doc.metadata.format, ir.Format.Source_BSP)
	testing.expect_value(t, len(doc.entities), 1)
	entity := doc.entities[0]
	testing.expect_value(t, entity.class_name, "func_brush")
	testing.expect_value(t, len(entity.brushes), 1)
	brush := doc.brushes[entity.brushes[0]]
	testing.expect_value(t, len(brush.faces), 6)
	for face in brush.faces {
		testing.expect_value(t, face.material, "DEV/DEV_TEST")
		// Texinfo stores texels-per-unit axes directly.
		testing.expect(t, face.uv.u.x == 1 && face.uv.v.y == 1)
		testing.expect(t, len(face.winding) == 4, "each cube side should evaluate to a quad")
	}
	// The model key is internal, not an entity property.
	testing.expect(t, !has_property(entity.props[:], "model"))
	value, has_target := ir.property_string(entity.props[:], "targetname")
	testing.expect(t, has_target)
	testing.expect_value(t, value, "test_brush")
}

has_property :: proc(props: []ir.Property, key: string) -> bool {
	for p in props {
		if p.key == key {
			return true
		}
	}
	return false
}
