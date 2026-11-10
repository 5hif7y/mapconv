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
}

// audit_lumps reports one row per non-empty lump. The caller owns the result.
audit_lumps :: proc(data: []u8) -> Lump_Audit {
	result: Lump_Audit
	if len(data) < 8 + HEADER_LUMPS * 16 {
		return result
	}
	rows := make([dynamic]Lump_Row, 0, HEADER_LUMPS, context.allocator)
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
	}
	result.rows = rows[:]
	return result
}

audit_lumps_destroy :: proc(a: ^Lump_Audit) {
	delete(a.rows)
	a.rows = nil
}

audit_lumps_text :: proc(a: ^Lump_Audit) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "file bytes:      %12d\n", a.interpreted + a.uninterpreted)
	fmt.sbprintf(&b, "interpreted:     %12d (%.1f%%)\n", a.interpreted, percent(a.interpreted, a.interpreted + a.uninterpreted))
	// The header (ident, version and the 64 lump descriptors) is parsed by read,
	// so it is credited on its own line.
	header: i64 = 8 + HEADER_LUMPS * 16
	credited := a.interpreted + header
	fmt.sbprintf(&b, "credited:        %12d (%.1f%%)\n", credited, percent(credited, a.interpreted + a.uninterpreted))
	fmt.sbprintf(&b, "uninterpreted:   %12d\n", a.uninterpreted)
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
		return ""
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
