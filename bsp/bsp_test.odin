package bsp

import "core:hash"
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

// build_stored_zip lays out the archive Source writes into lump 40: local records
// that tile the region, a central directory that repeats them and an end record.
// Every entry is stored, which is what the corpus shows in all 180,705 of them.
zip_u16 :: proc(d: ^[dynamic]u8, v: u16) { append(d, u8(v & 0xff), u8(v >> 8)) }
zip_u32 :: proc(d: ^[dynamic]u8, v: u32) {
	append(d, u8(v & 0xff), u8((v >> 8) & 0xff), u8((v >> 16) & 0xff), u8((v >> 24) & 0xff))
}

build_stored_zip :: proc(names: []string, bodies: [][]u8) -> []u8 {
	data: [dynamic]u8
	records := make([]int, len(names), context.allocator)
	defer delete(records)
	for name, i in names {
		records[i] = len(data)
		crc := hash.crc32(bodies[i])
		append(&data, u8('P'), u8('K'), 3, 4)
		zip_u16(&data, 20) // version needed
		zip_u16(&data, 0) // flags
		zip_u16(&data, 0) // method: stored
		zip_u16(&data, 0) // time
		zip_u16(&data, 0) // date
		zip_u32(&data, crc)
		zip_u32(&data, u32(len(bodies[i])))
		zip_u32(&data, u32(len(bodies[i])))
		zip_u16(&data, u16(len(name)))
		zip_u16(&data, 0) // extra
		append(&data, ..transmute([]u8)name)
		append(&data, ..bodies[i])
	}
	directory := len(data)
	for name, i in names {
		crc := hash.crc32(bodies[i])
		append(&data, u8('P'), u8('K'), 1, 2)
		zip_u16(&data, 20) // made by
		zip_u16(&data, 20) // needed
		zip_u16(&data, 0) // flags
		zip_u16(&data, 0) // method
		zip_u16(&data, 0) // time
		zip_u16(&data, 0) // date
		zip_u32(&data, crc)
		zip_u32(&data, u32(len(bodies[i])))
		zip_u32(&data, u32(len(bodies[i])))
		zip_u16(&data, u16(len(name)))
		zip_u16(&data, 0) // extra
		zip_u16(&data, 0) // comment
		zip_u16(&data, 0) // disk
		zip_u16(&data, 0) // internal attributes
		zip_u32(&data, 0) // external attributes
		zip_u32(&data, u32(records[i]))
		append(&data, ..transmute([]u8)name)
	}
	dir_size := len(data) - directory
	append(&data, u8('P'), u8('K'), 5, 6)
	zip_u16(&data, 0) // disk
	zip_u16(&data, 0) // directory disk
	zip_u16(&data, u16(len(names)))
	zip_u16(&data, u16(len(names)))
	zip_u32(&data, u32(dir_size))
	zip_u32(&data, u32(directory))
	zip_u16(&data, 0) // comment length
	return data[:]
}

@(test)
test_pakfile_is_verified_by_crc_and_tiling :: proc(t: ^testing.T) {
	bodies := [][]u8{transmute([]u8)string("materials/dev/dev_test.vmt"), transmute([]u8)string("hello")}
	names := []string{"materials/dev/dev_test.vmt", "readme.txt"}
	data := build_stored_zip(names, bodies)
	defer delete(data)
	report := verify_pakfile(data, 0, len(data))
	testing.expectf(t, report.reason == "", "valid archive rejected: %s", report.reason)
	testing.expect_value(t, report.entries, 2)
	testing.expect_value(t, report.verified, 2)
	testing.expect_value(t, report.stored, 2)
	testing.expect_value(t, report.payload, i64(len(bodies[0]) + len(bodies[1])))

	// One flipped payload byte has to be caught: the CRC is what turns a bounded
	// region into decoded content.
	mutated := make([]u8, len(data))
	defer delete(mutated)
	copy(mutated, data)
	mutated[40] ~= 0x01
	testing.expect(t, verify_pakfile(mutated, 0, len(mutated)).reason != "", "a wrong CRC has to be reported")

	// So has a truncated lump, which cannot even hold its directory.
	testing.expect(t, verify_pakfile(data, 0, len(data) - 3).reason != "", "a truncated archive has to be reported")

	// And a directory whose count does not match what it holds.
	broken := make([]u8, len(data))
	defer delete(broken)
	copy(broken, data)
	broken[len(data) - 12] = 9
	testing.expect(t, verify_pakfile(broken, 0, len(broken)).reason != "", "a wrong entry count has to be reported")
}

// A minimal map with a faces lump and a lighting lump: two faces of 2x2 luxels,
// the first at the start of the lump and the second far enough that the blocks do
// not touch.
build_lighting_map :: proc(second_lightofs: i32) -> []u8 {
	data := make([]u8, 8192)
	store_i32(data, 0, 20) // version
	faces_offset := 1024
	lighting_offset := 2048
	lighting_length := 256
	// Lump 7 (faces): two 56 byte records.
	store_i32(data, 8 + 7 * 16, i32(faces_offset))
	store_i32(data, 8 + 7 * 16 + 4, 112)
	store_i32(data, faces_offset + 0 * 56 + 20, 0) // lightofs
	store_i32(data, faces_offset + 0 * 56 + 36, 1) // size x: 2 luxels
	store_i32(data, faces_offset + 0 * 56 + 40, 1) // size y: 2 luxels
	store_i32(data, faces_offset + 1 * 56 + 20, second_lightofs)
	store_i32(data, faces_offset + 1 * 56 + 36, 1)
	store_i32(data, faces_offset + 1 * 56 + 40, 1)
	// Lump 8 (lighting).
	store_i32(data, 8 + 8 * 16, i32(lighting_offset))
	store_i32(data, 8 + 8 * 16 + 4, i32(lighting_length))
	return data
}

@(test)
test_lightmap_blocks_may_not_overlap :: proc(t: ^testing.T) {
	data := build_lighting_map(64)
	defer delete(data)
	testing.expect_value(t, lighting_reason(data, 8, 2048, 256), "")

	// Move the second face on top of the first: two faces cannot claim the same
	// samples, so one of the two offsets is not a sample offset.
	clash := build_lighting_map(8)
	defer delete(clash)
	testing.expect_value(t, lighting_reason(clash, 8, 2048, 256), "two lightmap blocks overlap")

	// A block that runs past the lump is caught as well.
	past := build_lighting_map(250)
	defer delete(past)
	testing.expect_value(t, lighting_reason(past, 8, 2048, 256), "lightmap sample block past the lump")
}

// A map with a leaf lump (two leaves), the ambient index for them and the ambient
// samples the index names: three samples for the first leaf and two for the second.
build_ambient_map :: proc(first_count: u16, second_first: u16, ambient_samples: int) -> []u8 {
	data := make([]u8, 8192)
	store_i32(data, 0, 0x50534256) // VBSP
	store_i32(data, 4, 20)         // version: 32 byte leaves
	leafs_offset := 1024
	index_offset := 2048
	ambient_offset := 3072
	// Lump 10 (leafs): two leaves of 32 bytes.
	store_i32(data, 8 + 10 * 16, i32(leafs_offset))
	store_i32(data, 8 + 10 * 16 + 4, 64)
	// Lump 52 (leafAmbientIndex): two records of {u16 count, u16 first}.
	store_i32(data, 8 + 52 * 16, i32(index_offset))
	store_i32(data, 8 + 52 * 16 + 4, 8)
	store_u16_bytes(data, index_offset, first_count)
	store_u16_bytes(data, index_offset + 2, 0)
	store_u16_bytes(data, index_offset + 4, 2)
	store_u16_bytes(data, index_offset + 6, second_first)
	// Lump 56 (leafAmbientLighting): 28 bytes per sample, pad byte zero.
	store_i32(data, 8 + 56 * 16, i32(ambient_offset))
	store_i32(data, 8 + 56 * 16 + 4, i32(ambient_samples * 28))
	return data
}

store_u16_bytes :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value & 0xff)
	data[offset + 1] = u8(value >> 8)
}

@(test)
test_leaf_ambient_index_tiles_the_sample_lump :: proc(t: ^testing.T) {
	data := build_ambient_map(3, 3, 5)
	defer delete(data)
	testing.expect_value(t, leaf_ambient_index_reason(data, 52, 2048, 8), "")
	testing.expect_value(t, leaf_ambient_reason(data, 56, 3072, 5 * 28), "")

	// One sample too many: the index and the lump disagree about how much the
	// leaves own.
	short := build_ambient_map(3, 3, 4)
	defer delete(short)
	testing.expect(t, leaf_ambient_reason(short, 56, 3072, 4 * 28) != "", "a short sample lump has to be reported")

	// Both leaves claiming the same samples.
	clash := build_ambient_map(3, 0, 5)
	defer delete(clash)
	testing.expect(t, leaf_ambient_index_reason(clash, 52, 2048, 8) != "", "overlapping leaves have to be reported")

	// A leaf lump that does not divide by the stride cannot be read at all.
	odd := build_ambient_map(3, 3, 5)
	defer delete(odd)
	store_i32(odd, 8 + 10 * 16 + 4, 60)
	testing.expect_value(t, leaf_ambient_index_reason(odd, 52, 2048, 8), "no leaf lump divisible by its stride to count the index against")
}

@(test)
test_entity_text_is_read_as_blocks :: proc(t: ^testing.T) {
	good := transmute([]u8)string("worldspawn\x00{\x00\"mapname\"\x00\"de_test\"\x00}\x00")
	testing.expect_value(t, entities_reason(good, 0, len(good)), "")

	// A key with no value before the block closes.
	lonely := transmute([]u8)string("worldspawn\x00{\x00\"mapname\"\x00}\x00")
	testing.expect_value(t, entities_reason(lonely, 0, len(lonely)), "a key has no value before the block closes")

	// Braces that never close.
	open := transmute([]u8)string("worldspawn\x00{\x00\"a\"\x00\"b\"\x00")
	testing.expect_value(t, entities_reason(open, 0, len(open)), "unbalanced braces")

	// The lump has to end with a terminator.
	cut := transmute([]u8)string("worldspawn\x00{\x00\"a\"\x00\"b\"\x00}")
	testing.expect_value(t, entities_reason(cut, 0, len(cut)), "the entity lump does not end with a terminator")
}

@(test)
test_face_ids_are_counted_against_the_faces :: proc(t: ^testing.T) {
	data := build_lighting_map(64) // two faces
	defer delete(data)
	face_ids_offset := 3000
	store_i32(data, 8 + 11 * 16, i32(face_ids_offset))
	store_i32(data, 8 + 11 * 16 + 4, 4) // two identifiers, two faces
	testing.expect_value(t, lump_reason(data, 11, face_ids_offset, 4), "")

	// One identifier more than the map has faces is a count that does not hold.
	testing.expect_value(t, lump_reason(data, 11, face_ids_offset, 6), "count is not one identifier per face")
}

@(test)
test_overlay_records_name_existing_faces :: proc(t: ^testing.T) {
	data := build_lighting_map(64) // two faces
	defer delete(data)
	overlay_offset := 5120
	store_i32(data, 8 + 45 * 16, i32(overlay_offset))
	store_i32(data, 8 + 45 * 16 + 4, 352)
	record := overlay_offset
	store_i32(data, record, 0) // id 0, its own index
	store_u16_bytes(data, record + 6, 2) // two faces
	store_i32(data, record + 8, 0)
	store_i32(data, record + 12, 1)
	testing.expect_value(t, lump_reason(data, 45, overlay_offset, 352), "")

	// A face index past the face lump belongs to no surface.
	store_i32(data, record + 12, 5)
	testing.expect_value(t, lump_reason(data, 45, overlay_offset, 352), "an overlay names a face that does not exist")

	// The id has to be the record's own index.
	store_i32(data, record + 12, 1)
	store_i32(data, record, 7)
	testing.expect_value(t, lump_reason(data, 45, overlay_offset, 352), "an overlay carries an id that is not its index")

	// A fade lump that holds anything but eight bytes per overlay contradicts it.
	store_i32(data, record, 0)
	store_i32(data, 8 + 60 * 16, 6144)
	store_i32(data, 8 + 60 * 16 + 4, 16) // two overlays' worth
	testing.expect_value(t, lump_reason(data, 45, overlay_offset, 352), "the fade lump does not hold eight bytes per overlay")
}

set_lump :: proc(data: []u8, index, offset, length: int) {
	store_i32(data, 8 + index * 16, i32(offset))
	store_i32(data, 8 + index * 16 + 4, i32(length))
}

// A map with one displacement of power 2: 25 vertices, 32 triangles, and one face
// of 2x2 luxels carrying it.
build_disp_map :: proc(power: i32, vertex_start: int, tri_start: int) -> []u8 {
	data := make([]u8, 16384)
	store_i32(data, 4, 20)
	faces_offset := 1024
	info_offset := 2048
	set_lump(data, 7, faces_offset, 56)
	set_lump(data, 26, info_offset, 176)
	set_lump(data, 33, 4096, 25 * 20)
	set_lump(data, 48, 6144, 32 * 2)
	set_lump(data, 30, 7168, 3 * 12) // three normals
	// The face carries a displacement and a 2x2 luxel lightmap.
	store_u16_bytes(data, faces_offset + 12, 0) // dispinfo index 0
	store_u16_bytes(data, faces_offset + 8, 3) // three vertices, so three normal indices
	store_i32(data, faces_offset + 36, 1)
	store_i32(data, faces_offset + 40, 1)
	// The displacement record.
	store_i32(data, info_offset + 12, i32(vertex_start))
	store_i32(data, info_offset + 16, i32(tri_start))
	store_i32(data, info_offset + 20, power)
	return data
}

@(test)
test_displacement_runs_add_up_to_their_lumps :: proc(t: ^testing.T) {
	data := build_disp_map(2, 0, 0)
	defer delete(data)
	testing.expect_value(t, dispinfo_reason(data, 2048, 176), "")
	testing.expect_value(t, disp_tri_reason(data, 6144, 64), "")
	testing.expect_value(t, disp_lightmap_alpha_reason(data, 8192, 4), "")
	testing.expect_value(t, vert_normal_index_reason(data, 9216, 6), "")

	// A triangle lump that does not hold two bytes per triangle the records name.
	testing.expect_value(t, disp_tri_reason(data, 6144, 66), "triangle count does not match the displacement infos")

	// A vertex run that does not continue the previous one.
	moved := build_disp_map(2, 7, 0)
	defer delete(moved)
	testing.expect_value(t, dispinfo_reason(moved, 2048, 176), "a displacement vertex run does not continue the previous one")

	// A power outside the range the corpus shows.
	bad_power := build_disp_map(9, 0, 0)
	defer delete(bad_power)
	testing.expect_value(t, dispinfo_reason(bad_power, 2048, 176), "displacement power outside 2..4")

	// One byte per luxel: the face says 2x2, so four bytes and not five.
	testing.expect_value(t, disp_lightmap_alpha_reason(data, 8192, 5), "count is not one byte per displacement lightmap luxel")

	// Three vertices means three normal indices, and each has to name a normal.
	testing.expect_value(t, vert_normal_index_reason(data, 9216, 8), "count is not one index per vertex a face uses")
	store_u16_bytes(data, 9216, 3) // only three normals exist
	testing.expect_value(t, vert_normal_index_reason(data, 9216, 6), "a normal index is past the normal lump")
}
