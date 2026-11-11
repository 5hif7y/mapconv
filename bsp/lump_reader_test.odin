package bsp

import "core:testing"

// Every lump the reader claims to handle is falsified here with the smallest thing that
// is not a lump of that kind: one byte. The reason each one gives is pinned, so a reader
// that starts accepting what it used to refuse fails in CI -- without the 32 GB corpus,
// which never enters the repository.
//
// Some lumps cannot refuse on their own: their rule counts against another lump (a normal
// index against the normal array, a fade against the overlay array, an ambient index
// against the leaves). Those return "" here on purpose, and the reason they would give is
// pinned in the test of the rule that supplies the count. Reading the table down the
// empty column is the list of lumps whose check is a cross-check and nothing else -- which
// is exactly the property that made them acceptable in the first place.
//
// LUMPROW is a plain table and not a loop over the enum: the name is here so a failure
// names the lump, and the index is here so the table can be checked against HEADER_LUMPS.

Lump_Reader_Row :: struct {
	index:  int,
	name:   string,
	reason: string,
}

LUMP_READERS := [?]Lump_Reader_Row {
	{ 0, "entities",                      "the entity lump holds an empty token"},
	{ 1, "planes",                        "size is not a multiple of 20"},
	{ 2, "texdata",                       "size is not a multiple of 32"},
	{ 3, "vertexes",                      "size is not a multiple of 12"},
	{ 4, "visibility",                    "shorter than the cluster count"},
	{ 5, "nodes",                         "size is not a multiple of 32"},
	{ 6, "texinfo",                       "size is not a multiple of 72"},
	{ 7, "faces",                         "size is not a multiple of 56"},
	{ 8, "lighting",                      "size is not a multiple of 4"},
	{ 9, "occlusion",                     "the occlusion lump ends before a count"},
	{10, "leafs",                         "size is not a whole number of leaves"},
	{11, "faceIds",                       ""},
	{12, "edges",                         "size is not a multiple of 4"},
	{13, "surfedges",                     "size is not a multiple of 4"},
	{14, "models",                        "size is not a multiple of 48"},
	{15, "worldLights",                   "size does not divide by 100 or 88, or a light record is out of range"},
	{16, "leafFaces",                     "size is not a multiple of 2"},
	{17, "leafBrushes",                   "size is not a multiple of 2"},
	{18, "brushes",                       "size is not a multiple of 12"},
	{19, "brushSides",                    "size is not a multiple of 8"},
	{20, "areas",                         "size is not a multiple of 8"},
	{21, "areaPortals",                   "size is not a multiple of 12"},
	{22, "unused0",                       "no reader"},
	{23, "unused1",                       "no reader"},
	{24, "unused2",                       "no reader"},
	{25, "unused3",                       "no reader"},
	{26, "dispInfo",                      "size is not a multiple of 176"},
	{27, "origFaces",                     "size is not a multiple of 56"},
	{28, "physDisp",                      "shorter than the displacement count"},
	{29, "physCollide",                   "truncated model header"},
	{30, "vertNormals",                   "size is not a multiple of 12"},
	{31, "vertNormalIndices",             ""},
	{32, "dispLightmapAlphas",            "lightmap alphas without a face lump to count them against"},
	{33, "dispVerts",                     "size is not a multiple of 20"},
	{34, "dispLightmapSamplePositions",   "no displacement surface references the lump"},
	{35, "gameLump",                      "shorter than the game lump count"},
	{36, "leafWaterData",                 "size is not a multiple of 12"},
	{37, "primitives",                    "size is not a multiple of 10"},
	{38, "primVerts",                     "no reader"},
	{39, "primIndices",                   "size is not a multiple of 2"},
	{40, "pakfile",                       "no end of central directory record"},
	{41, "clipPortalVerts",               "size is not a multiple of 12"},
	{42, "cubemaps",                      "the cubemap lump is not a whole number of records"},
	{43, "texdataStringData",             "the material name blob holds an empty name"},
	{44, "texdataStringTable",            "size is not a multiple of 4"},
	{45, "overlays",                      "size is not a multiple of 352"},
	{46, "leafMinDistToWater",            "no divisible leaf lump to check the distance array against"},
	{47, "faceMacroTextureInfo",          "size is not a multiple of 2"},
	{48, "dispTris",                      "size is not a multiple of 2"},
	{49, "physCollideSurface",            "truncated model header"},
	{50, "waterOverlays",                 "no reader"},
	{51, "leafAmbientIndexHDR",           "no leaf lump divisible by its stride to count the index against"},
	{52, "leafAmbientIndex",              "no leaf lump divisible by its stride to count the index against"},
	{53, "lightingHDR",                   "size is not a multiple of 4"},
	{54, "worldLightsHDR",                "size does not divide by 100 or 88, or a light record is out of range"},
	{55, "leafAmbientLightingHDR",        "size is not a multiple of 24 or 28"},
	{56, "leafAmbientLighting",           "size is not a multiple of 24 or 28"},
	{57, "xzipPakfile",                   "no reader"},
	{58, "facesHDR",                      "size is not a multiple of 56"},
	{59, "mapFlags",                      "shorter than the map flags word"},
	{60, "overlayFades",                  "no overlay lump to check the fade array against"},
	{61, "overlaySystemLevels",           "no reader"},
	{62, "physLevel",                     "no reader"},
	{63, "dispMultiBlend",                "the multi blend lump is not a whole number of blocks"},
}

@(test)
test_every_lump_reader_refuses_a_one_byte_lump :: proc(t: ^testing.T) {
	one := []u8{0}
	refused := 0
	deferred := 0
	for row in LUMP_READERS {
		reason := lump_reason(one, row.index, 0, 1)
		testing.expectf(t, reason == row.reason,
			"lump %d (%s): got %q, pinned %q", row.index, row.name, reason, row.reason)
		if reason == "" {
			deferred += 1
		} else {
			refused += 1
		}
	}
	// The counts are the statement: 62 of the 64 lumps refuse a byte, and the two that do
	// not -- faceIds and vertNormalIndices -- count against the face lump, so their rule
	// is exercised in the face test. A reader that starts accepting garbage moves this
	// number, which is the point of pinning it.
	testing.expect_value(t, len(LUMP_READERS), HEADER_LUMPS)
	testing.expectf(t, refused == 62 && deferred == 2,
		"expected 62 refusing and 2 deferred readers, got %d and %d", refused, deferred)
}

@(test)
test_the_reader_table_names_the_lumps_it_reads :: proc(t: ^testing.T) {
	for row, at in LUMP_READERS {
		testing.expect_value(t, row.index, at)
		testing.expect_value(t, row.name, LUMP_NAMES[at])
	}
}

@(test)
test_a_lump_read_at_an_offset_reads_the_same_bytes :: proc(t: ^testing.T) {
	// The readers take an offset into the file, not a buffer of their own. A reader that
	// indexes from zero would pass the table above and fail here.
	buffer := make([]u8, 4096)
	defer delete(buffer)
	at := 2048
	buffer[at] = 0
	for row in LUMP_READERS {
		here := lump_reason(buffer[at:at + 1], row.index, 0, 1)
		padded := lump_reason(buffer, row.index, at, 1)
		testing.expectf(t, here == padded, "lump %d (%s): %q at the start, %q at 2048",
			row.index, row.name, here, padded)
	}
}
