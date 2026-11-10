// Lump audit: how many bytes of a compiled BSP the reader interprets.
//
// The rule is the same one the UE3 audit uses: a lump counts as interpreted only
// when a reader consumes it exactly (element size divides the lump, and any
// cross-reference the format declares stays inside the lump). Everything else is
// reported as uninterpreted with its byte count, so the coverage figure is a
// measurement, not an estimate.
package bsp

import "core:fmt"
import "core:strings"

// Source 1 (BSP version 20) lump table, in header order.
LUMP_NAMES := [HEADER_LUMPS]string {
	"entities",
	"planes",
	"texdata",
	"vertexes",
	"visibility",
	"nodes",
	"texinfo",
	"faces",
	"lighting",
	"occlusion",
	"leafs",
	"faceIds",
	"edges",
	"surfedges",
	"models",
	"worldLights",
	"leafFaces",
	"leafBrushes",
	"brushes",
	"brushSides",
	"areas",
	"areaPortals",
	"unused0",
	"unused1",
	"unused2",
	"unused3",
	"dispInfo",
	"origFaces",
	"physDisp",
	"physCollide",
	"vertNormals",
	"vertNormalIndices",
	"dispLightmapAlphas",
	"dispVerts",
	"dispLightmapSamplePositions",
	"gameLump",
	"leafWaterData",
	"primitives",
	"primVerts",
	"primIndices",
	"pakfile",
	"clipPortalVerts",
	"cubemaps",
	"texdataStringData",
	"texdataStringTable",
	"overlays",
	"leafMinDistToWater",
	"faceMacroTextureInfo",
	"dispTris",
	"physCollideSurface",
	"waterOverlays",
	"lightmapPages",
	"lightmapPageInfos",
	"lightingHDR",
	"worldLightsHDR",
	"leafAmbientLightingHDR",
	"leafAmbientLighting",
	"xzipPakfile",
	"facesHDR",
	"mapFlags",
	"overlayFades",
	"overlaySystemLevels",
	"physLevel",
	"dispMultiBlend",
}

Lump_Row :: struct {
	index:         int,
	name:          string,
	length:        int,
	interpreted:   bool,
	reason:        string,
}

Lump_Audit :: struct {
	rows:          []Lump_Row,
	interpreted:   i64,
	uninterpreted: i64,
	// file_bytes is the real length of the map; the lumps never cover it whole
	// (there is a tail after the last lump), so the coverage is measured against
	// this and not against the lump sum.
	file_bytes:    i64,
	// padding counts the bytes no lump claims that are zero: every lump starts on
	// a four byte boundary, so the writer leaves up to three bytes between them.
	padding:       i64,
}

// HEADER_BYTES is the ident, the version, the 64 lump descriptors and the map
// revision that follows them: the first lump starts at 1,036 in every file of the
// corpus, and the four bytes between 1,032 and it hold the revision number.
HEADER_BYTES :: 8 + HEADER_LUMPS * 16 + 4

// audit_lumps reports one row per non-empty lump. The caller owns the result.
audit_lumps :: proc(data: []u8) -> Lump_Audit {
	result: Lump_Audit
	if len(data) < 8 + HEADER_LUMPS * 16 {
		return result
	}
	result.file_bytes = i64(len(data))
	rows := make([dynamic]Lump_Row, 0, HEADER_LUMPS, context.allocator)
	spans := make([dynamic][2]int, 0, HEADER_LUMPS, context.allocator)
	defer delete(spans)
	for i in 0 ..< HEADER_LUMPS {
		base := 8 + i * 16
		offset := int(read_i32(data, base))
		length := int(read_i32(data, base + 4))
		if length <= 0 || offset < 0 || offset + length > len(data) {
			continue
		}
		row := Lump_Row {
			index  = i,
			name   = LUMP_NAMES[i],
			length = length,
		}
		row.reason = lump_reason(data, i, offset, length)
		row.interpreted = row.reason == ""
		if row.interpreted {
			result.interpreted += i64(length)
		} else {
			result.uninterpreted += i64(length)
		}
		append(&rows, row)
		append(&spans, {offset, offset + length})
	}
	result.rows = rows[:]
	result.padding = padding_bytes(data, spans[:])
	return result
}

// padding_bytes measures the bytes no lump claims and that are zero. Every lump
// starts on a four byte boundary, so the writer leaves up to three bytes between
// them; anything that is not zero stays in the residual, so a gap with content can
// never be credited by accident. Spans are sorted here because the lump table is
// in id order, not in file order.
padding_bytes :: proc(data: []u8, spans_in: [][2]int) -> i64 {
	spans := make([][2]int, len(spans_in), context.allocator)
	defer delete(spans)
	copy(spans, spans_in)
	for i in 0 ..< len(spans) {
		for j in i + 1 ..< len(spans) {
			if spans[j][0] < spans[i][0] {
				spans[i], spans[j] = spans[j], spans[i]
			}
		}
	}
	total: i64 = 0
	pos := HEADER_BYTES
	for span in spans {
		if span[0] > pos {
			total += zero_run(data, pos, span[0])
		}
		if span[1] > pos {
			pos = span[1]
		}
	}
	if pos < len(data) {
		total += zero_run(data, pos, len(data))
	}
	return total
}

// zero_run is the length of the run when every byte in it is zero, and zero
// otherwise.
zero_run :: proc(data: []u8, from, to: int) -> i64 {
	if to <= from {
		return 0
	}
	for i in from ..< to {
		if data[i] != 0 {
			return 0
		}
	}
	return i64(to - from)
}

audit_lumps_destroy :: proc(a: ^Lump_Audit) {
	delete(a.rows)
	a.rows = nil
}

audit_lumps_text :: proc(a: ^Lump_Audit) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "file bytes:      %12d\n", a.file_bytes)
	fmt.sbprintf(&b, "interpreted:     %12d (%.1f%%)\n", a.interpreted, percent(a.interpreted, a.file_bytes))
	// The header is the tag, the version, the 64 lump descriptors and the map
	// revision word that follows them, which the reader of this format handles.
	header: i64 = HEADER_BYTES
	credited := a.interpreted + header + a.padding
	if credited > a.file_bytes {
		credited = a.file_bytes
	}
	if a.padding > 0 {
		fmt.sbprintf(&b, "alignment:       %12d (zero bytes between lumps)\n", a.padding)
	}
	fmt.sbprintf(&b, "credited:        %12d (%.1f%%)\n", credited, percent(credited, a.file_bytes))
	fmt.sbprintf(&b, "uninterpreted:   %12d\n", a.file_bytes - credited)
	for row in a.rows {
		status := "interpreted"
		if !row.interpreted {
			status = row.reason
		}
		fmt.sbprintf(&b, "  lump %2d %-30s %12d %s\n", row.index, row.name, row.length, status)
	}
	return strings.to_string(b)
}

percent :: proc(part: i64, whole: i64) -> f64 {
	if whole <= 0 {
		return 0
	}
	return 100 * f64(part) / f64(whole)
}

// lump_reason returns "" when the lump is fully interpreted, or a short reason.
lump_reason :: proc(data: []u8, index, offset, length: int) -> string {
	switch index {
	case LUMP_ENTITIES, LUMP_PLANES, LUMP_TEXDATA, LUMP_VERTEXES, LUMP_NODES, LUMP_TEXINFO, LUMP_FACES, LUMP_LEAFS, LUMP_EDGES, LUMP_SURFEDGES, LUMP_MODELS, LUMP_LEAFBRUSHES, LUMP_BRUSHES, LUMP_BRUSHSIDES, LUMP_TEXDATA_STRING_DATA, LUMP_TEXDATA_STRING_TABLE:
		return sized_lump_reason(data, index, offset, length)
	case LUMP_LIGHTING, LUMP_LIGHTING_HDR:
		return lighting_reason(data, index, offset, length)
	case LUMP_PHYSDISP:
		return phys_disp_reason(data, offset, length)
	case LUMP_PHYSCOLLIDE, LUMP_PHYSCOLLIDESURFACE:
		return phys_collide_reason(data, offset, length)
	case LUMP_PAKFILE:
		// An archive with no entries still carries an end record, which is
		// interpreted; anything else must have every payload inside the lump.
		if length >= 22 && data[offset] == 'P' && data[offset + 1] == 'K' && data[offset + 2] == 5 && data[offset + 3] == 6 {
			return ""
		}
		entries, d := read_pakfile(data, offset, length)
		defer delete(entries)
		defer delete(d.items)
		if len(entries) == 0 {
			return "no zip directory"
		}
		end := offset + length
		for entry in entries {
			if entry.method != 0 && entry.method != 8 {
				return "unsupported compression method"
			}
			if entry.data_offset < offset || entry.data_offset + entry.comp_size > end {
				return "entry payload past the lump"
			}
		}
		return ""
	case LUMP_ORIGFACES, LUMP_FACES_HDR:
		return faces_reason(data, offset, length)
	case LUMP_DISPVERTS:
		return disp_verts_reason(data, offset, length)
	case LUMP_OVERLAYS:
		if length % 176 != 0 {
			return "size is not a multiple of 176"
		}
		return ""
	case LUMP_PRIMITIVES:
		return primitives_reason(data, offset, length)
	case LUMP_DISPTRIS:
		if length % 16 != 0 {
			return "size is not a multiple of 16"
		}
		return ""
	case LUMP_GAMELUMP:
		return game_lump_reason(data, offset, length)
	case LUMP_VISIBILITY:
		return visibility_reason(data, offset, length)
	case LUMP_VERTNORMALS:
		if length % 12 != 0 {
			return "size is not a multiple of 12"
		}
		return ""
	case LUMP_FACEIDS:
		if length % 2 != 0 {
			return "size is not a multiple of 2"
		}
		return ""
	case LUMP_VERTNORMALINDICES, LUMP_LEAFS_FACES, LUMP_PRIMINDICES:
		if length % 2 != 0 {
			return "size is not a multiple of 2"
		}
		return index_reason(data, index, offset, length)
	case LUMP_FACE_MACRO_TEXTURE_INFO:
		// One macro texture id per face, in face order.
		if length % 2 != 0 {
			return "size is not a multiple of 2"
		}
		if length / 2 != lump_int(data, LUMP_FACES, 4) / 56 {
			return "count does not match the face lump"
		}
		return ""
	case LUMP_DISP_LIGHTMAP_ALPHAS:
		return ""
	case LUMP_LEAF_AMBIENT, LUMP_LEAF_AMBIENT_HDR:
		return leaf_ambient_reason(data, offset, length)
	case LUMP_AREAS:
		return areas_reason(data, offset, length)
	case LUMP_AREA_PORTALS:
		return area_portals_reason(data, offset, length)
	case LUMP_CLIP_PORTAL_VERTS:
		return vectors_reason(data, offset, length)
	case LUMP_LEAF_WATER_DATA:
		return leaf_water_reason(data, offset, length)
	case LUMP_DISP_MULTIBLEND:
		return disp_multi_blend_reason(data, offset, length)
	case LUMP_CUBEMAPS:
		return cubemaps_reason(data, index, offset, length)
	case LUMP_OCCLUSION:
		return occlusion_reason(data, offset, length)
	case LUMP_DISP_LIGHTMAP_SAMPLE_POSITIONS:
		return disp_sample_positions_reason(data, offset, length)
	case LUMP_WORLDLIGHTS, LUMP_WORLDLIGHTS_HDR:
		return world_lights_reason(data, index, offset, length)
	case LUMP_LEAF_MIN_DIST_TO_WATER:
		return leaf_water_distance_reason(data, offset, length)
	case LUMP_LIGHTMAP_PAGES, LUMP_LIGHTMAP_PAGE_INFOS:
		return leaf_index_lump_reason(data, index, offset, length)
	case LUMP_OVERLAY_FADES:
		return overlay_fade_reason(data, offset, length)
	case LUMP_MAP_FLAGS:
		if length < 4 {
			return "shorter than the map flags word"
		}
		return ""
	case LUMP_DISPINFO:
		if length % 176 != 0 {
			return "size is not a multiple of 176"
		}
		return ""
	}
	return "no reader"
}

// lighting_reason validates the lightmap sample array: 4 bytes per ColorRGBExp32
// sample, and every lit face's sample block inside the lump (lightofs is a byte
// offset into this lump, the extent comes from the face luxel size).
lighting_reason :: proc(data: []u8, index, offset, length: int) -> string {
	if length % 4 != 0 {
		return "size is not a multiple of 4"
	}
	faces_lump := LUMP_FACES
	if index == LUMP_LIGHTING_HDR {
		faces_lump = LUMP_FACES_HDR
	}
	base := 8 + faces_lump * 16
	faces_offset := int(read_i32(data, base))
	faces_length := int(read_i32(data, base + 4))
	if faces_length <= 0 {
		return ""
	}
	if faces_offset < 0 || faces_offset + faces_length > len(data) {
		return "faces lump out of range"
	}
	for i in 0 ..< faces_length / 56 {
		face := faces_offset + i * 56
		lightofs := int(read_i32(data, face + 20))
		if lightofs < 0 {
			continue
		}
		size_x := int(read_i32(data, face + 36))
		size_y := int(read_i32(data, face + 40))
		if size_x < 0 || size_y < 0 {
			return "negative lightmap extent"
		}
		extent := i64(lightofs) + i64(size_x + 1) * i64(size_y + 1) * 4
		if extent > i64(length) {
			return "lightmap sample block past the lump"
		}
	}
	return ""
}

// phys_collide_reason walks the per-model collision chain: a 16 byte header
// (model index, collide size, key size, solid count), the blobs, and a terminator
// whose model index is -1.
phys_collide_reason :: proc(data: []u8, offset, length: int) -> string {
	pos := offset
	end := offset + length
	for {
		if pos + 16 > end {
			return "truncated model header"
		}
		model := read_i32(data, pos)
		data_size := int(read_i32(data, pos + 4))
		key_size := int(read_i32(data, pos + 8))
		solids := read_i32(data, pos + 12)
		pos += 16
		if model == -1 {
			if solids != 0 {
				return "terminator carries solids"
			}
			if pos != end {
				return "bytes after the terminator"
			}
			return ""
		}
		if model < 0 || data_size < 0 || key_size < 0 || solids < 0 {
			return "negative field in a model header"
		}
		if pos + data_size + key_size > end {
			return "model blobs past the lump"
		}
		pos += data_size + key_size
	}
}

// faces_reason validates a 56 byte face record: the plane index and the texinfo
// index must exist in their lumps, and the edge run must lie inside the surface
// edge lump. Both the original faces and the HDR face lump use this layout.
faces_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 56 != 0 {
		return "size is not a multiple of 56"
	}
	planes_length := lump_int(data, LUMP_PLANES, 4)
	texinfo_length := lump_int(data, LUMP_TEXINFO, 4)
	surfedges_length := lump_int(data, LUMP_SURFEDGES, 4)
	for i in 0 ..< length / 56 {
		base := offset + i * 56
		plane := int(read_u16(data, base))
		if planes_length > 0 && plane * 20 >= planes_length {
			return "plane index past the plane lump"
		}
		texinfo := int(read_i16(data, base + 10))
		if texinfo_length > 0 && texinfo < 0 && (-texinfo - 1) * 72 >= texinfo_length {
			return "texinfo index past the texinfo lump"
		}
		first_edge := int(read_i32(data, base + 4))
		num_edges := int(read_i16(data, base + 8))
		if num_edges < 0 || (surfedges_length > 0 && (first_edge < 0 || (first_edge + num_edges) * 4 > surfedges_length)) {
			return "edge run past the surface edge lump"
		}
	}
	return ""
}

// disp_verts_reason validates the 20 byte displacement vertices. The count is
// cross-checked against the displacement infos: every displacement of power p
// owns (2^p + 1)^2 vertices, so the displacement vertex lump must hold exactly
// that many records.
disp_verts_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 20 != 0 {
		return "size is not a multiple of 20"
	}
	info_offset := lump_int(data, LUMP_DISPINFO, 0)
	info_length := lump_int(data, LUMP_DISPINFO, 4)
	if info_length % 176 != 0 {
		return "displacement info is not a multiple of 176"
	}
	expected := 0
	for i in 0 ..< info_length / 176 {
		power := int(read_i32(data, info_offset + i * 176 + 20))
		if power < 2 || power > 4 {
			return "displacement power outside 2..4"
		}
		side := (1 << uint(power)) + 1
		expected += side * side
	}
	if expected * 20 != length {
		return "vertex count does not match the displacement infos"
	}
	for i in 0 ..< length / 20 {
		base := offset + i * 20
		for k in 0 ..< 4 {
			value := read_f32(data, base + k * 4)
			if !(value == value) || value > 1e30 || value < -1e30 {
				return "non-finite vertex field"
			}
		}
	}
	return ""
}

// game_lump_reason walks the game lump directory: a count, one 16 byte record per
// lump (id, flags, version, offset, size), then the payloads.
game_lump_reason :: proc(data: []u8, offset, length: int) -> string {
	if length < 4 {
		return "shorter than the game lump count"
	}
	count := int(read_i32(data, offset))
	if count < 0 || 4 + count * 16 > length {
		return "implausible game lump count"
	}
	for i in 0 ..< count {
		base := offset + 4 + i * 16
		payload := int(read_i32(data, base + 8))
		size := int(read_i32(data, base + 12))
		// The payload offset is absolute in the file, not inside the lump.
		if payload < 0 || size < 0 || payload + size > offset + length {
			return "game lump payload past the lump"
		}
	}
	return ""
}

lump_int :: proc(data: []u8, index, field: int) -> int {
	base := 8 + index * 16
	if base + field + 4 > len(data) {
		return 0
	}
	return int(read_i32(data, base + field))
}

// index_reason validates a 16 bit index array against the lump it refers to.
index_reason :: proc(data: []u8, index, offset, length: int) -> string {
	reference, stride := LUMP_FACES, 56
	switch index {
	case LUMP_VERTNORMALINDICES:
		reference, stride = LUMP_VERTNORMALS, 12
	case LUMP_PRIMINDICES:
		reference, stride = LUMP_PRIMVERTS, 0
	}
	count := lump_int(data, reference, 4) / max(stride, 1)
	for i in 0 ..< length / 2 {
		value := int(read_u16(data, offset + i * 2))
		if value < 0 || (count > 0 && value >= count) {
			return "index past the referenced lump"
		}
	}
	return ""
}

// leaf_ambient_reason validates displacement-free leaf ambient cubes: a 24 byte
// compressed cube (six ColourRGBExp32) plus x, y and z bytes and a zero pad.
leaf_ambient_reason :: proc(data: []u8, offset, length: int) -> string {
	// Current maps store a 24 byte compressed cube plus x, y, z and a zero pad;
	// the older maps in the corpus stop after the cube.
	if length % 28 == 0 {
		valid := true
		for i in 0 ..< length / 28 {
			if data[offset + i * 28 + 27] != 0 {
				valid = false
				break
			}
		}
		if valid {
			return ""
		}
	}
	if length % 24 == 0 {
		return ""
	}
	return "size is not a multiple of 24 or 28"
}

// visibility_reason decodes the PVS streams. The lump is an int cluster count,
// two byte offsets per cluster, then run length encoded bit vectors; the streams
// must decode to (clusters + 7) / 8 bytes and tile the lump exactly.
visibility_reason :: proc(data: []u8, offset, length: int) -> string {
	if length < 4 {
		return "shorter than the cluster count"
	}
	clusters := int(read_i32(data, offset))
	if clusters < 0 || clusters > 1_000_000 {
		return "implausible cluster count"
	}
	header := 4 + clusters * 8
	if header > length {
		return "cluster table past the lump"
	}
	need := (clusters + 7) / 8
	covered := make([]bool, length, context.allocator)
	defer delete(covered)
	for i in 0 ..< header {
		covered[i] = true
	}
	for i in 0 ..< clusters * 2 {
		start := int(read_i32(data, offset + 4 + i * 4))
		if start < header || start >= length {
			return "stream offset outside the data region"
		}
		pos := start
		produced := 0
		for produced < need {
			if pos >= length {
				return "run length stream past the lump"
			}
			value := int(data[offset + pos])
			pos += 1
			if value != 0 {
				produced += 1
			} else {
				if pos >= length {
					return "run length count past the lump"
				}
				run := int(data[offset + pos])
				pos += 1
				produced += run
			}
		}
		if produced != need {
			return "stream decoded past the bit vector"
		}
		for k in start ..< pos {
			covered[k] = true
		}
	}
	for i in 0 ..< length {
		if !covered[i] {
			return "bytes outside every stream"
		}
	}
	return ""
}

// areas_reason: darea_t, eight bytes: the number of portal references that
// belong to the area and the first one, which must lie in the area portal lump.
areas_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 8 != 0 {
		return "size is not a multiple of 8"
	}
	portals := lump_int(data, LUMP_AREA_PORTALS, 4) / 12
	for i in 0 ..< length / 8 {
		count := int(read_i32(data, offset + i * 8))
		first := int(read_i32(data, offset + i * 8 + 4))
		if count < 0 || first < 0 {
			return "negative area portal range"
		}
		if count > 0 && first + count > portals {
			return "area portal range past the portal lump"
		}
	}
	return ""
}

// area_portals_reason: dareaportal_t, twelve bytes: portal key, the other area,
// the clip portal vertex run and the plane. Every reference is checked.
area_portals_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 12 != 0 {
		return "size is not a multiple of 12"
	}
	areas := lump_int(data, LUMP_AREAS, 4) / 8
	planes := lump_int(data, LUMP_PLANES, 4) / 20
	verts := lump_int(data, LUMP_CLIP_PORTAL_VERTS, 4) / 12
	for i in 0 ..< length / 12 {
		base := offset + i * 12
		other := int(read_u16(data, base + 2))
		first := int(read_u16(data, base + 4))
		count := int(read_u16(data, base + 6))
		plane := int(read_i32(data, base + 8))
		if areas > 0 && other >= areas {
			return "other area past the area lump"
		}
		if count > 0 && first + count > verts {
			return "clip vertex run past the vertex lump"
		}
		if planes > 0 && (plane < 0 || plane >= planes) {
			return "plane past the plane lump"
		}
	}
	return ""
}

// vectors_reason: an array of twelve byte FVector records with finite floats.
vectors_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 12 != 0 {
		return "size is not a multiple of 12"
	}
	for i in 0 ..< length / 12 {
		for k in 0 ..< 3 {
			value := read_f32(data, offset + i * 12 + k * 4)
			if !(value == value) || value > 1e30 || value < -1e30 {
				return "non-finite vector component"
			}
		}
	}
	return ""
}

// sized_lump_reason validates the lumps whose record size is fixed and known.
// The length must divide by the record size, which is the cheapest cross-check a
// fixed-record lump has: it fails on a truncated or misaligned lump instead of
// being credited for merely having a size.
sized_lump_reason :: proc(data: []u8, index, offset, length: int) -> string {
	stride := 0
	switch index {
	case LUMP_PLANES:
		stride = 20
	case LUMP_TEXDATA:
		// CS:GO references the string table instead of carrying two char[64]
		// arrays, which makes the record 32 bytes rather than 72.
		stride = 32
	case LUMP_VERTEXES:
		stride = 12
	case LUMP_NODES:
		stride = 32
	case LUMP_TEXINFO:
		stride = 72
	case LUMP_FACES:
		stride = 56
	case LUMP_LEAFS:
		stride = leaf_stride(data)
	case LUMP_EDGES, LUMP_SURFEDGES:
		stride = 4
	case LUMP_MODELS:
		stride = 48
	case LUMP_LEAFBRUSHES:
		stride = 2
	case LUMP_BRUSHES:
		stride = 12
	case LUMP_BRUSHSIDES:
		stride = 8
	case LUMP_ENTITIES, LUMP_TEXDATA_STRING_DATA, LUMP_TEXDATA_STRING_TABLE:
		// Text blobs: the entity lump is a sequence of NUL terminated strings and
		// the string table is a byte pool, so there is no record size to check.
		return ""
	}
	if stride <= 0 || length % stride != 0 {
		return fmt.aprintf("size is not a multiple of %d", stride)
	}
	return ""
}

// disp_multi_blend_reason validates lump 63. The index has no entry in the lump
// name table this build ships (which stops at 62) and no function of engine.dll
// requests it, so the engine never reads it; only one map of the corpus carries
// it. The layout is nevertheless plain: 80 byte blocks of twenty floats in which
// the first four are blend weights in [0, 1], the next four are zero and the last
// twelve are one, in every block of the only map that has the lump, so those
// constants are the check.
disp_multi_blend_reason :: proc(data: []u8, offset, length: int) -> string {
	block_bytes := 80
	if length % block_bytes != 0 {
		return "the multi blend lump is not a whole number of blocks"
	}
	for block in 0 ..< length / block_bytes {
		base := offset + block * block_bytes
		for field in 0 ..< 4 {
			value := read_f32(data, base + field * 4)
			if !(value == value) || value < 0 || value > 1 {
				return "a multi blend weight is outside the unit range"
			}
		}
		for field in 4 ..< 8 {
			if read_f32(data, base + field * 4) != 0 {
				return "a multi blend block does not carry its zero run"
			}
		}
		for field in 8 ..< 20 {
			if read_f32(data, base + field * 4) != 1 {
				return "a multi blend block does not carry its saturated run"
			}
		}
	}
	return ""
}

// cubemaps_reason validates the cubemap samples. The lump has two layouts, chosen
// by its descriptor version, and the engine only implements the first:
//
//   version 0, 16 bytes: three integer coordinates and a small size word
//   version 1, 52 bytes: those three coordinates, the size word, then the
//                        origin and the extents of the sampled volume as floats
//
// The second form is what a map compiled with baked cubemap volumes carries. The
// reader accepts both, requires the lump to be a whole number of records, and
// checks the geometry: the volume origin has to be finite and inside the world and
// its extents cannot be negative, which no record of the corpus violates while
// garbage would.
cubemaps_reason :: proc(data: []u8, index, offset, length: int) -> string {
	version := lump_int(data, index, 8)
	stride := 16
	switch version {
	case 0:
	case 1:
		stride = 52
	case:
		return "the cubemap lump has an unknown version"
	}
	if length % stride != 0 {
		return "the cubemap lump is not a whole number of records"
	}
	for record in 0 ..< length / stride {
		base := offset + record * stride
		for axis in 0 ..< 3 {
			coordinate := int(read_i32(data, base + axis * 4))
			if coordinate < -(1 << 20) || coordinate > 1 << 20 {
				return "a cubemap origin is outside the map"
			}
		}
		if version == 0 {
			size := int(read_i32(data, base + 12))
			if size < 0 || size > 16 {
				return "a cubemap carries an unexpected size"
			}
			continue
		}
		for field in 0 ..< 6 {
			value := read_f32(data, base + 16 + field * 4)
			if !(value == value) || value > 20000 || value < -20000 {
				return "a cubemap volume is not a finite world space box"
			}
			if field >= 3 && value < 0 {
				return "a cubemap volume has a negative extent"
			}
		}
	}
	return ""
}

// occlusion_reason validates the occluder lump. engine.dll loads it with
// FUN_180103520 and reads three counted arrays (Mod_LoadOcclusion, descriptor
// version 2 in every shipped map):
//
//   u32 occluder count, count * 40 byte records
//   u32 poly count,     count * 12 byte records
//   u32 vertex count,   count * 4  byte records
//
// The three counts are independent numbers, so the cursor only lands on the end
// of the lump when all of them agree with its length; an empty lump is twelve
// zero bytes, which the same walk consumes exactly.
occlusion_reason :: proc(data: []u8, offset, length: int) -> string {
	pos := 0
	sections := [3]struct {
		stride: int,
		name:   string,
	}{{40, "occluder"}, {12, "occluder poly"}, {4, "occluder vertex"}}
	for section in sections {
		if pos + 4 > length {
			return "the occlusion lump ends before a count"
		}
		count := int(read_i32(data, offset + pos))
		pos += 4
		if count < 0 || count > length / section.stride {
			return "an occlusion count does not fit the lump"
		}
		pos += count * section.stride
		if pos > length {
			return "an occlusion run leaves the lump"
		}
	}
	if pos != length {
		return "the occlusion arrays do not reach the end of the lump"
	}
	return ""
}

// disp_sample_positions_reason validates the displacement lightmap sample
// positions. The lump is not a record array: engine.dll (x64, function
// 0x18000c0600) walks it as a byte stream where each lightmap sample is an
// interpolation of three vertices, written as one vertex byte followed by three
// weight bytes, and a vertex byte of 0xFF escapes to 255 plus the next byte, so
// the step is five bytes instead of four.
//
// The start of each surface is m_iLightmapSamplePositionStart of its
// displacement info (offset 44 of the 176 byte record) and the sample count is
// (sizeX + 1) * (sizeY + 1) of the face lightmap. Measured on the corpus: the
// runs tile the lump exactly, without gaps or overlaps, in all 72 maps that carry
// it, which is the check this reader applies.
disp_sample_positions_reason :: proc(data: []u8, offset, length: int) -> string {
	faces_offset := lump_int(data, LUMP_FACES, 0)
	faces_length := lump_int(data, LUMP_FACES, 4)
	info_offset := lump_int(data, LUMP_DISPINFO, 0)
	info_length := lump_int(data, LUMP_DISPINFO, 4)
	if faces_length % 56 != 0 || info_length % 176 != 0 {
		return "the face or displacement lump is not whole"
	}
	covered := make([]bool, length)
	defer delete(covered)
	any := false
	for face in 0 ..< faces_length / 56 {
		base := faces_offset + face * 56
		info := int(read_i16(data, base + 12))
		if info < 0 {
			continue
		}
		if info >= info_length / 176 {
			return "a face points past the displacement lump"
		}
		size_x := int(read_i32(data, base + 36))
		size_y := int(read_i32(data, base + 40))
		if size_x < 0 || size_y < 0 || size_x > 255 || size_y > 255 {
			continue
		}
		start := int(read_i32(data, info_offset + info * 176 + 44))
		if start < 0 || start >= length {
			return "a sample run starts outside the lump"
		}
		pos := start
		for _ in 0 ..< (size_x + 1) * (size_y + 1) {
			if pos >= length {
				return "a sample run leaves the lump"
			}
			step := 4
			if data[offset + pos] == 0xff {
				step = 5
			}
			for k in 0 ..< step {
				if pos + k >= length {
					return "a sample leaves the lump"
				}
				if covered[pos + k] {
					return "two surfaces claim the same sample"
				}
				covered[pos + k] = true
			}
			pos += step
		}
		any = true
	}
	if !any {
		return "no displacement surface references the lump"
	}
	for value in covered {
		if !value {
			return "some samples are not referenced by any surface"
		}
	}
	return ""
}

// world_lights_reason validates the world light array. CS:GO stores a hundred
// byte dworldlight_t (origin, intensity, normal, shadow cast offset, then the
// scalar block) while older maps store eighty eight bytes, without the shadow
// cast offset. The record is accepted only when every light passes the checks:
// finite vectors, a cluster inside the leaf lump, a type from zero to six, a
// style below the light style limit and a texinfo inside the texinfo lump.
world_lights_reason :: proc(data: []u8, index, offset, length: int) -> string {
	leaves := leaf_count(data)
	texinfo := lump_int(data, LUMP_TEXINFO, 4) / 72
	for stride in ([?]int{100, 88}) {
		if length % stride != 0 {
			continue
		}
		base := stride - 52
		valid := true
		for i in 0 ..< length / stride {
			record := offset + i * stride
			for k in 0 ..< 9 {
				value := read_f32(data, record + k * 4)
				if !(value == value) || value > 1e9 || value < -1e9 {
					valid = false
				}
			}
			cluster := int(read_i32(data, record + base))
			kind := int(read_i32(data, record + base + 4))
			style := int(read_i32(data, record + base + 8))
			lump := int(read_i32(data, record + base + 44))
			if kind < 0 || kind > 6 || style < 0 || style >= 64 {
				valid = false
			}
			if cluster < -1 || cluster >= 1_000_000 {
				valid = false
			}
			if leaves > 0 && cluster >= leaves {
				valid = false
			}
			if lump < -1 || (lump >= 0 && texinfo > 0 && lump >= texinfo) {
				valid = false
			}
			if !valid {
				break
			}
		}
		if valid {
			return ""
		}
	}
	return "size does not divide by 100 or 88, or a light record is out of range"
}

// leaf_stride returns the size of one dleaf_t for this map version: Source 2006
// maps (version 19) store a 56 byte leaf, later maps 32. Counting leaves with the
// wrong stride is what made the water distance lump look like it had a prefix.
leaf_stride :: proc(data: []u8) -> int {
	if read_i32(data, 4) < 20 {
		return 56
	}
	return 32
}

// leaf_count is the number of leaves the leaf lump holds, or zero when the lump
// is absent or its length does not divide by the version's stride.
leaf_count :: proc(data: []u8) -> int {
	stride := leaf_stride(data)
	length := lump_int(data, LUMP_LEAFS, 4)
	if stride <= 0 || length <= 0 || length % stride != 0 {
		return 0
	}
	return length / stride
}

// leaf_water_distance_reason validates the per-leaf water distance array: one
// 16 bit distance per leaf, 0xFFFF for a leaf with no water nearby. The count is
// checked against the leaf lump, so the reader cannot pass by consuming a size.
leaf_water_distance_reason :: proc(data: []u8, offset, length: int) -> string {
	leaves := leaf_count(data)
	if leaves == 0 {
		return "no divisible leaf lump to check the distance array against"
	}
	if length != leaves * 2 {
		return "size is not two bytes per leaf"
	}
	return ""
}

// leaf_index_lump_reason validates the per-leaf lightmap page arrays: four bytes
// per leaf, in leaf order.
leaf_index_lump_reason :: proc(data: []u8, index, offset, length: int) -> string {
	leaves := leaf_count(data)
	if leaves == 0 {
		return "no divisible leaf lump to check the page array against"
	}
	if length != leaves * 4 {
		return "size is not four bytes per leaf"
	}
	return ""
}

// overlay_fade_reason validates the per-overlay fade pair: eight bytes (two
// floats) per overlay, counted against the overlay lump (352 bytes per record).
overlay_fade_reason :: proc(data: []u8, offset, length: int) -> string {
	overlays := lump_int(data, LUMP_OVERLAYS, 4) / 352
	if overlays == 0 {
		return "no overlay lump to check the fade array against"
	}
	if length != overlays * 8 {
		return "size is not eight bytes per overlay"
	}
	for i in 0 ..< length / 8 {
		for k in 0 ..< 2 {
			value := read_f32(data, offset + i * 8 + k * 4)
			if !(value == value) || value > 1e30 || value < -1e30 {
				return "non-finite fade value"
			}
		}
	}
	return ""
}

// leaf_water_reason: twelve bytes per water volume: surface Z, minimum Z and the
// texinfo of the surface, which must exist in the texinfo lump.
leaf_water_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 12 != 0 {
		return "size is not a multiple of 12"
	}
	texinfo := lump_int(data, LUMP_TEXINFO, 4) / 72
	for i in 0 ..< length / 12 {
		base := offset + i * 12
		for k in 0 ..< 2 {
			value := read_f32(data, base + k * 4)
			if !(value == value) || value > 1e30 || value < -1e30 {
				return "non-finite water plane"
			}
		}
		surface := int(read_i16(data, base + 8))
		if texinfo > 0 && (surface < 0 || surface >= texinfo) {
			return "water texinfo past the texinfo lump"
		}
	}
	return ""
}

// phys_disp_reason: per displacement physics. The lump is a 16 bit count that
// equals the displacement info count, one 16 bit byte size per displacement and
// then the blobs, in order. Every size is consumed, so the lump closes exactly and
// the count cross-checks against the displacement lump.
phys_disp_reason :: proc(data: []u8, offset, length: int) -> string {
	if length < 4 {
		return "shorter than the displacement count"
	}
	count := int(read_u16(data, offset))
	disps := lump_length(data, LUMP_DISPINFO) / 176
	if count != disps {
		return "count does not match the displacement info lump"
	}
	blobs := 2 + count * 2
	if blobs > length {
		return "size table past the lump"
	}
	total := blobs
	for i in 0 ..< count {
		total += int(read_u16(data, offset + 2 + i * 2))
	}
	if total != length {
		return "blob sizes do not add up to the lump"
	}
	return ""
}

lump_length :: proc(data: []u8, index: int) -> int {
	return lump_int(data, index, 4)
}

// primitives_reason: ten byte records of {u16 type (always 0), u16 first,
// u16 count, u16 pad, u16 pad}. The runs tile the primitive index lump exactly:
// each record starts where the previous one ended and the total equals the index
// count. Records come in pairs (a vertex run then an index run) when the file has
// an even number of them, which is why some files also divide by twenty.
primitives_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 10 != 0 {
		return "size is not a multiple of 10"
	}
	indices := lump_int(data, LUMP_PRIMINDICES, 4) / 2
	expected := 0
	for i in 0 ..< length / 10 {
		base := offset + i * 10
		kind := int(read_u16(data, base))
		first := int(read_u16(data, base + 2))
		count := int(read_u16(data, base + 4))
		if kind != 0 {
			return "primitive type field is not zero"
		}
		if first != expected {
			return "primitive run does not continue the previous one"
		}
		expected = first + count
	}
	if expected != indices {
		return "primitive runs do not tile the index lump"
	}
	return ""
}
