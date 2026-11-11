package bsp

// A map the repository can carry: one of every lump the reader interprets, in one file,
// small enough to live in a test. The corpus is 32 GB and stays out of the repository, so
// this is where the readers meet each other -- a lump that only agrees with the corpus and
// not with its neighbours is a lump whose rule was written for one file.
//
// The fixture is built, not checked in, so it is also readable: every field below is named
// and set on purpose, and the bytes it does not set are zero because zero is a legal value
// for them. What the test asserts is that the audit refuses nothing, credits the whole
// file, and counts what the fixture put there.

import "core:testing"

TINY_SIZE :: 32 * 1024

tiny_build :: struct {
	data:    []u8,
	lengths: [HEADER_LUMPS]int,
	offsets: [HEADER_LUMPS]int,
}

// tiny_put copies one lump into the file and records where it went. Lumps are laid out in
// index order on four byte boundaries, which is what every shipped map does.
tiny_put :: proc(build: ^tiny_build, index: int, bytes: []u8) {
	offset := HEADER_BYTES
	for i in 0 ..< index {
		if build.lengths[i] > 0 {
			offset = build.offsets[i] + build.lengths[i]
			offset += (4 - offset % 4) % 4
		}
	}
	// Lumps are placed after the last lump already written, in index order, so the
	// placement above is only a start; find the real end.
	last := HEADER_BYTES
	for i in 0 ..< HEADER_LUMPS {
		if build.lengths[i] > 0 {
			end := build.offsets[i] + build.lengths[i]
			end += (4 - end % 4) % 4
			if end > last {
				last = end
			}
		}
	}
	_ = offset
	copy(build.data[last:], bytes)
	build.offsets[index] = last
	build.lengths[index] = len(bytes)
}

build_tiny_map :: proc() -> []u8 {
	data, _ := build_tiny_map_at()
	return data
}

// build_tiny_map_at also returns where each lump landed, so a test can reach into one and
// break it on purpose.
build_tiny_map_at :: proc() -> (data: []u8, offsets: [HEADER_LUMPS]int) {
	build := tiny_build {
		data = make([]u8, TINY_SIZE),
	}
	store_i32(build.data, 0, 0x50534256) // VBSP
	store_i32(build.data, 4, 20) // version: 32 byte leaves

	// The world: one quad, one face, one plane, one material, one leaf, one node, one
	// model, one brush -- a room smaller than a luxel grid cell.
	{
		entities := transmute([]u8)string("{\n\"classname\" \"worldspawn\"\n}\n\x00")
		tiny_put(&build, LUMP_ENTITIES, entities)
	}
	{
		planes := make([]u8, 20)
		store_f32(planes, 2 * 4, 1) // normal (0, 0, 1)
		store_f32(planes, 3 * 4, 0) // distance
		tiny_put(&build, LUMP_PLANES, planes)
		defer delete(planes)
	}
	{
		texdata := make([]u8, 32)
		store_f32(texdata, 0, 1) // reflectivity
		store_u16_bytes(texdata, 12, 0) // name index into the string table
		store_u16_bytes(texdata, 14, 16) // 16 x 16
		store_u16_bytes(texdata, 16, 16)
		tiny_put(&build, LUMP_TEXDATA, texdata)
		defer delete(texdata)
	}
	{
		vertices := make([]u8, 4 * 12)
		corners := [4][2]f32{{0, 0}, {96, 0}, {96, 96}, {0, 96}}
		for corner, i in corners {
			store_f32(vertices, i * 12 + 0, corner[0])
			store_f32(vertices, i * 12 + 4, corner[1])
			store_f32(vertices, i * 12 + 8, 64)
		}
		tiny_put(&build, LUMP_VERTEXES, vertices)
		defer delete(vertices)
	}
	{
		edges := make([]u8, 4 * 4)
		for i in 0 ..< 4 {
			store_u16_bytes(edges, i * 4 + 0, u16(i))
			store_u16_bytes(edges, i * 4 + 2, u16((i + 1) % 4))
		}
		tiny_put(&build, LUMP_EDGES, edges)
		defer delete(edges)
	}
	{
		surfedges := make([]u8, 4 * 4)
		for i in 0 ..< 4 {
			store_i32(surfedges, i * 4, i32(i + 1))
		}
		tiny_put(&build, LUMP_SURFEDGES, surfedges)
		defer delete(surfedges)
	}
	{
		texinfo := make([]u8, 72)
		store_f32(texinfo, 32 + 0 * 4, 0.0625) // lightmap axes: one luxel per 16 units
		store_f32(texinfo, 32 + 1 * 4 + 4, -0.0625)
		tiny_put(&build, LUMP_TEXINFO, texinfo)
		defer delete(texinfo)
	}
	{
		faces := make([]u8, 56)
		store_u16_bytes(faces, 0, 0) // plane 0
		store_i32(faces, 4, 0) // first surfedge
		store_i16_bytes(faces, 8, 4) // four edges
		store_i16_bytes(faces, 10, 0) // texinfo 0
		store_i16_bytes(faces, 12, -1) // no displacement
		faces[16] = 0 // one style
		faces[17] = 0xff
		faces[18] = 0xff
		faces[19] = 0xff
		store_i32(faces, 20, 4) // lightofs: past one style word
		store_i32(faces, 36, 2) // 3 x 3 luxels
		store_i32(faces, 40, 2)
		store_i32(faces, 44, 0) // origFace
		tiny_put(&build, LUMP_FACES, faces)
		defer delete(faces)
	}
	{
		// One style word, then the nine luxels of the face.
		lighting := make([]u8, 4 + 9 * 4)
		for i in 0 ..< 9 {
			lighting[4 + i * 4 + 0] = 255
			lighting[4 + i * 4 + 3] = 0xFC // exponent -4
		}
		tiny_put(&build, LUMP_LIGHTING, lighting)
		defer delete(lighting)
	}
	{
		// One cluster, two streams of one byte each: the run length encoding the engine
		// decodes, with the cluster visible to itself.
		// Two streams of one literal byte each, packed one after the other: the walk
		// covers every byte of the lump, which is one of the rules it checks.
		visibility := make([]u8, 14)
		store_i32(visibility, 0, 1)
		store_i32(visibility, 4, 12)
		store_i32(visibility, 8, 13)
		visibility[12] = 1
		visibility[13] = 1
		tiny_put(&build, LUMP_VISIBILITY, visibility)
		defer delete(visibility)
	}
	{
		leafs := make([]u8, 32)
		store_i16_bytes(leafs, 4, 0) // cluster 0
		store_u16_bytes(leafs, 20, 0) // first leaf face
		store_u16_bytes(leafs, 22, 1) // one leaf face
		store_u16_bytes(leafs, 24, 0) // first leaf brush
		store_u16_bytes(leafs, 26, 1) // one leaf brush
		store_i16_bytes(leafs, 28, -1) // no water
		tiny_put(&build, LUMP_LEAFS, leafs)
		defer delete(leafs)
	}
	{
		nodes := make([]u8, 32)
		store_i16_bytes(nodes, 28, 0) // area 0
		store_u16_bytes(nodes, 24, 0) // first face
		store_u16_bytes(nodes, 26, 1) // one face
		tiny_put(&build, LUMP_NODES, nodes)
		defer delete(nodes)
	}
	{
		models := make([]u8, 48)
		store_i32(models, 36, 0) // headnode
		store_i32(models, 40, 0) // first face
		store_i32(models, 44, 1) // one face
		tiny_put(&build, LUMP_MODELS, models)
		defer delete(models)
	}
	{
		brushes := make([]u8, 12)
		store_i32(brushes, 4, 1) // one side
		tiny_put(&build, LUMP_BRUSHES, brushes)
		defer delete(brushes)
	}
	{
		brush_sides := make([]u8, 8)
		store_i16_bytes(brush_sides, 2, 0) // texinfo
		store_i16_bytes(brush_sides, 4, -1) // no displacement
		tiny_put(&build, LUMP_BRUSHSIDES, brush_sides)
		defer delete(brush_sides)
	}
	{
		leaf_faces := make([]u8, 4)
		store_u16_bytes(leaf_faces, 2, 1) // first leaf face 0, one face
		tiny_put(&build, LUMP_LEAFS_FACES, leaf_faces[0:2])
		defer delete(leaf_faces)
	}
	{
		leaf_brushes := make([]u8, 4)
		store_u16_bytes(leaf_brushes, 2, 1)
		tiny_put(&build, LUMP_LEAFBRUSHES, leaf_brushes[0:2])
		defer delete(leaf_brushes)
	}
	{
		areas := make([]u8, 8)
		tiny_put(&build, LUMP_AREAS, areas)
		defer delete(areas)
	}
	{
		face_ids := make([]u8, 2)
		tiny_put(&build, LUMP_FACEIDS, face_ids)
		defer delete(face_ids)
	}
	{
		normals := make([]u8, 12)
		store_f32(normals, 8, 1)
		tiny_put(&build, LUMP_VERTNORMALS, normals)
		defer delete(normals)
	}
	{
		indices := make([]u8, 8) // four edges, four indices, all on the one normal
		tiny_put(&build, LUMP_VERTNORMALINDICES, indices)
		defer delete(indices)
	}
	{
		names := transmute([]u8)string("TOOLS/TOOLSNODRAW\x00")
		tiny_put(&build, LUMP_TEXDATA_STRING_DATA, names)
		table := make([]u8, 4)
		tiny_put(&build, LUMP_TEXDATA_STRING_TABLE, table)
		defer delete(table)
	}
	{
		primitives := make([]u8, 10)
		store_u16_bytes(primitives, 4, 1) // one index
		tiny_put(&build, LUMP_PRIMITIVES, primitives)
		defer delete(primitives)
		prim_indices := make([]u8, 2)
		tiny_put(&build, LUMP_PRIMINDICES, prim_indices)
		defer delete(prim_indices)
	}
	{
		cubemaps := make([]u8, 16) // version 0: origin, size
		tiny_put(&build, LUMP_CUBEMAPS, cubemaps)
		defer delete(cubemaps)
	}
	{
		world_lights := make([]u8, 88)
		store_i32(world_lights, 52, 0) // cluster
		store_i32(world_lights, 56, 0) // type
		store_i32(world_lights, 60, 0) // style
		tiny_put(&build, LUMP_WORLDLIGHTS, world_lights)
		defer delete(world_lights)
	}
	{
		// The ambient cube of the leaf: one sample, 24 bytes, and the leaf index that
		// names it.
		samples := make([]u8, 24)
		tiny_put(&build, LUMP_LEAF_AMBIENT, samples)
		defer delete(samples)
		index := make([]u8, 4)
		store_u16_bytes(index, 0, 1) // one sample
		tiny_put(&build, LUMP_LEAF_AMBIENT_INDEX, index)
		defer delete(index)
	}
	{
		water := make([]u8, 2) // one distance, one leaf
		store_u16_bytes(water, 0, 0xFFFF)
		tiny_put(&build, LUMP_LEAF_MIN_DIST_TO_WATER, water)
		defer delete(water)
	}
	{
		// Collision: one model, one solid with the VPHY header, then the terminator.
		collide := make([]u8, 16 + 16 + 16)
		store_i32(collide, 0, 0) // model 0
		store_i32(collide, 4, 16) // collide bytes
		store_i32(collide, 8, 0) // key bytes
		store_i32(collide, 12, 1) // one solid
		store_i32(collide, 16, 12) // solid size
		copy(collide[20:24], "VPHY")
		store_u16_bytes(collide, 24, PHYS_SOLID_VERSION)
		store_i32(collide, 28, 0) // surface size: 12 - 0 = the record size
		store_i32(collide, 32, -1) // terminator
		tiny_put(&build, LUMP_PHYSCOLLIDE, collide)
		defer delete(collide)
	}
	{
		names := []string{"maps/tiny.txt"}
		bodies := [][]u8{transmute([]u8)string("hello")}
		archive := build_stored_zip(names, bodies)
		tiny_put(&build, LUMP_PAKFILE, archive)
		defer delete(archive)
	}
	{
		flags := make([]u8, 4)
		tiny_put(&build, LUMP_MAP_FLAGS, flags)
		defer delete(flags)
	}

	// The lump table.
	total := HEADER_BYTES
	for length, index in build.lengths {
		if length <= 0 {
			continue
		}
		store_i32(build.data, 8 + index * 16, i32(build.offsets[index]))
		store_i32(build.data, 8 + index * 16 + 4, i32(length))
		end := build.offsets[index] + length
		if end > total {
			total = end
		}
	}
	result := make([]u8, total)
	copy(result, build.data[:total])
	delete(build.data)
	return result, build.offsets
}

store_f32 :: proc(data: []u8, offset: int, value: f32) {
	bits := transmute(u32)value
	data[offset + 0] = u8(bits)
	data[offset + 1] = u8(bits >> 8)
	data[offset + 2] = u8(bits >> 16)
	data[offset + 3] = u8(bits >> 24)
}

@(test)
test_the_tiny_map_reads_every_lump_it_carries :: proc(t: ^testing.T) {
	data := build_tiny_map()
	defer delete(data)
	audit := audit_lumps(data)
	defer audit_lumps_destroy(&audit)

	testing.expectf(t, audit.uninterpreted == 0, "the fixture was refused:\n%s", audit_lumps_text(&audit))
	testing.expect_value(t, len(audit.rows), 33)
	testing.expect_value(t, audit.lightmap_tiled, 1)
	testing.expect_value(t, audit.lightmap_luxels, i64(9))
	testing.expect_value(t, audit.pakfile_entries, 1)
	testing.expect_value(t, audit.pakfile_verified, 1)
	testing.expect_value(t, audit.phys_models, 1)
	testing.expect_value(t, audit.phys_solids, 1)
	// Header, every lump and the alignment between them: the fixture is fully explained.
	testing.expect_value(t, audit.interpreted + HEADER_BYTES + audit.padding, audit.file_bytes)
}

// The fixture is only worth carrying if it can fail. Each of these breaks one rule in one
// lump and expects the reason that rule gives: the map is small enough that a rule without
// a falsifier here is a rule that was never contradicted.

@(test)
test_the_tiny_map_refuses_a_face_that_points_outside_the_geometry :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	// The face lump is audited by its stride only. A face that names a plane the plane
	// lump does not have is refused by `faces_reason`, which the original and HDR face
	// arrays use; a positive texinfo index is not refused here at all -- the reader
	// resolves it to no material (`texinfo_of` bounds it) and that is the boundary.
	testing.expect_value(t, lump_reason(data, LUMP_FACES, offsets[LUMP_FACES], 56), "")
	testing.expect_value(t, faces_reason(data, offsets[LUMP_FACES], 56), "")

	store_u16_bytes(data, offsets[LUMP_FACES] + 0, 9) // one plane in the plane lump
	testing.expect_value(t, faces_reason(data, offsets[LUMP_FACES], 56),
		"plane index past the plane lump")

	store_u16_bytes(data, offsets[LUMP_FACES] + 0, 0)
	store_i32(data, offsets[LUMP_FACES] + 4, 3) // four edges from the third of four
	testing.expectf(t, faces_reason(data, offsets[LUMP_FACES], 56) != "",
		"an edge run past the surface edge lump was accepted")
}

@(test)
test_the_tiny_map_refuses_a_leaf_in_a_cluster_the_visibility_lump_does_not_have :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	store_i16_bytes(data, offsets[LUMP_LEAFS] + 4, 3)
	testing.expect_value(t, lump_reason(data, LUMP_VISIBILITY, offsets[LUMP_VISIBILITY], 14),
		"the cluster count is not one more than the largest leaf cluster")
}

@(test)
test_the_tiny_map_refuses_a_visibility_stream_that_leaves_bytes_unread :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	// Move the second stream one byte further: the byte in between belongs to neither.
	store_i32(data, offsets[LUMP_VISIBILITY] + 8, 14) // the second stream skips byte 13
	data[offsets[LUMP_VISIBILITY] + 13] = 0xA5
	data[offsets[LUMP_VISIBILITY] + 14] = 1
	testing.expect_value(t, lump_reason(data, LUMP_VISIBILITY, offsets[LUMP_VISIBILITY], 15),
		"bytes outside every stream")
}

@(test)
test_the_tiny_map_refuses_a_lightmap_region_that_starts_at_the_wrong_offset :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	store_i32(data, offsets[LUMP_FACES] + 20, 0) // one style: the samples start at 4
	tiled, _, _, _, _ := lightmap_tiling(data, LUMP_LIGHTING)
	testing.expectf(t, !tiled, "the region at the wrong offset still tiled the lump")
	// A block that runs past the lump is the other half of the rule, and it is the one
	// the lump reader reports.
	store_i32(data, offsets[LUMP_FACES] + 20, 40)
	testing.expect_value(t, lighting_reason(data, LUMP_LIGHTING, offsets[LUMP_LIGHTING], 40),
		"lightmap sample block past the lump")
}

@(test)
test_the_tiny_map_refuses_a_pakfile_whose_crc_does_not_match :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	// The stored payload of the one entry, past the local header.
	data[offsets[LUMP_PAKFILE] + 30 + 4] = 'H'
	report := verify_pakfile(data, offsets[LUMP_PAKFILE], lump_int(data, LUMP_PAKFILE, 4))
	testing.expectf(t, report.reason != "", "the archive with a changed payload was accepted")
	testing.expect_value(t, report.verified, 0)
}

@(test)
test_the_tiny_map_refuses_collision_for_a_model_that_does_not_exist :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	store_i32(data, offsets[LUMP_PHYSCOLLIDE] + 0, 1) // one model in the model lump
	testing.expect_value(t, lump_reason(data, LUMP_PHYSCOLLIDE, offsets[LUMP_PHYSCOLLIDE], 48),
		"collision for a model the model lump does not have")
}

@(test)
test_the_tiny_map_refuses_an_ambient_index_that_names_no_samples :: proc(t: ^testing.T) {
	data, offsets := build_tiny_map_at()
	defer delete(data)
	store_u16_bytes(data, offsets[LUMP_LEAF_AMBIENT_INDEX] + 0, 0) // the leaf names none
	testing.expectf(t, lump_reason(data, LUMP_LEAF_AMBIENT_INDEX, offsets[LUMP_LEAF_AMBIENT_INDEX], 4) != "",
		"an ambient lump no leaf owns was accepted")
}
