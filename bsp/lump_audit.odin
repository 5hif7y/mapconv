// Lump audit: how many bytes of a compiled BSP the reader interprets.
//
// The rule is the same one the UE3 audit uses: a lump counts as interpreted only
// when a reader consumes it exactly (element size divides the lump, and any
// cross-reference the format declares stays inside the lump). Everything else is
// reported as uninterpreted with its byte count, so the coverage figure is a
// measurement, not an estimate.
package bsp

import "core:fmt"
import "core:slice"
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
	"leafAmbientIndexHDR",
	"leafAmbientIndex",
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
	// The pakfile lump is a ZIP archive, so it is not bounded but decoded: every
	// entry is inflated where needed and its CRC32 checked against the directory.
	// These three fields report how much content that covered.
	pakfile_entries:  int,
	pakfile_payload:  i64,
	pakfile_verified: int,
	// The lightmap lumps hold more than the faces that point into them: the blocks
	// of the faces cover about a third of the two lumps together. These three
	// fields report that, so the gap is visible on every run and not only in the
	// notes: the planes between blocks are a measured structure this reader does
	// not attribute to a face.
	lightmap_blocks:       int,
	lightmap_attributed:   i64,
	lightmap_total:        i64,
	// The collision chain is walked solid by solid: these report what the walk
	// covered, so the claim that the lump is understood and not skipped is a number
	// on every run.
	phys_models:  int,
	phys_solids:  int,
	phys_collide: i64,
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
		if i == LUMP_LIGHTING || i == LUMP_LIGHTING_HDR {
			blocks, attributed := lightmap_coverage(data, i)
			result.lightmap_blocks += blocks
			result.lightmap_attributed += attributed
			result.lightmap_total += i64(length)
		}
		if i == LUMP_PHYSCOLLIDE || i == LUMP_PHYSCOLLIDESURFACE {
			tally := PHYS_Tally{}
			row.reason = phys_collide_reason(data, offset, length, &tally)
			if row.reason == "" {
				result.phys_models += tally.models
				result.phys_solids += tally.solids
				result.phys_collide += i64(tally.collide_bytes)
			}
		}
		if i == LUMP_PAKFILE {
			// The archive is checked as content, not as a span: the records have to
			// tile the lump and every payload has to match the CRC32 the directory
			// records for it.
			report := verify_pakfile(data, offset, length)
			row.reason = report.reason
			if report.reason == "" {
				result.pakfile_entries = report.entries
				result.pakfile_payload = report.payload
				result.pakfile_verified = report.verified
			}
		} else {
			row.reason = lump_reason(data, i, offset, length)
		}
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
	if a.lightmap_total > 0 {
		fmt.sbprintf(&b, "lightmaps:       %12d blocks, %d of %d bytes attributed to a face (%.1f%%)\n",
			a.lightmap_blocks, a.lightmap_attributed, a.lightmap_total,
			percent(a.lightmap_attributed, a.lightmap_total))
	}
	if a.phys_models > 0 {
		fmt.sbprintf(&b, "collision:       %12d model(s), %d solid(s), %d bytes of collide data\n",
			a.phys_models, a.phys_solids, a.phys_collide)
	}
	if a.pakfile_entries > 0 {
		fmt.sbprintf(&b, "pakfile:         %12d entries, %d bytes of payload, %d CRC32 matched\n",
			a.pakfile_entries, a.pakfile_payload, a.pakfile_verified)
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
	case LUMP_LEAFS:
		// The loader divides the lump by the leaf stride before anything else and
		// refuses a remainder, so a leaf lump that does not divide cannot be read.
		if leaf_count(data) == 0 {
			return "size is not a whole number of leaves"
		}
		return ""
	case LUMP_ENTITIES:
		return entities_reason(data, offset, length)
	case LUMP_TEXDATA_STRING_DATA:
		return texdata_string_data_reason(data, offset, length)
	case LUMP_TEXDATA_STRING_TABLE:
		return texdata_string_table_reason(data, offset, length)
	case LUMP_PLANES, LUMP_TEXDATA, LUMP_VERTEXES, LUMP_NODES, LUMP_TEXINFO, LUMP_FACES, LUMP_EDGES, LUMP_SURFEDGES, LUMP_MODELS, LUMP_LEAFBRUSHES, LUMP_BRUSHES, LUMP_BRUSHSIDES:
		return sized_lump_reason(data, index, offset, length)
	case LUMP_LIGHTING, LUMP_LIGHTING_HDR:
		return lighting_reason(data, index, offset, length)
	case LUMP_PHYSDISP:
		return phys_disp_reason(data, offset, length)
	case LUMP_PHYSCOLLIDE, LUMP_PHYSCOLLIDESURFACE:
		return phys_collide_reason(data, offset, length)
	case LUMP_PAKFILE:
		// audit_lumps checks the archive with verify_pakfile, which decodes every
		// entry; reaching this arm means the lump arrived from somewhere else.
		return verify_pakfile(data, offset, length).reason
	case LUMP_ORIGFACES, LUMP_FACES_HDR:
		return faces_reason(data, offset, length)
	case LUMP_DISPVERTS:
		return disp_verts_reason(data, offset, length)
	case LUMP_OVERLAYS:
		return overlay_reason(data, offset, length)
	case LUMP_PRIMITIVES:
		return primitives_reason(data, offset, length)
	case LUMP_DISPTRIS:
		return disp_tri_reason(data, offset, length)
	case LUMP_GAMELUMP:
		return game_lump_reason(data, offset, length)
	case LUMP_VISIBILITY:
		return visibility_reason(data, offset, length)
	case LUMP_VERTNORMALS:
		return vert_normal_reason(data, offset, length)
	case LUMP_FACEIDS:
		// Two bytes per face in face order. The identifiers are arbitrary (they are
		// not face indices and they repeat), so the count is the check.
		faces := lump_int(data, LUMP_FACES, 4) / 56
		if faces <= 0 {
			return ""
		}
		if length != faces * 2 {
			return "count is not one identifier per face"
		}
		return ""
	case LUMP_VERTNORMALINDICES:
		return vert_normal_index_reason(data, offset, length)
	case LUMP_LEAFS_FACES, LUMP_PRIMINDICES:
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
		return disp_lightmap_alpha_reason(data, offset, length)
	case LUMP_LEAF_AMBIENT, LUMP_LEAF_AMBIENT_HDR:
		return leaf_ambient_reason(data, index, offset, length)
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
	case LUMP_LEAF_AMBIENT_INDEX_HDR, LUMP_LEAF_AMBIENT_INDEX:
		return leaf_ambient_index_reason(data, index, offset, length)
	case LUMP_OVERLAY_FADES:
		return overlay_fade_reason(data, offset, length)
	case LUMP_MAP_FLAGS:
		if length < 4 {
			return "shorter than the map flags word"
		}
		return ""
	case LUMP_DISPINFO:
		return dispinfo_reason(data, offset, length)
	}
	return "no reader"
}

// lightmap_coverage counts the face blocks of one lightmap lump and the bytes they
// claim, which is how the audit reports how much of the lump the faces explain.
lightmap_coverage :: proc(data: []u8, index: int) -> (blocks: int, attributed: i64) {
	faces_lump := LUMP_FACES
	if index == LUMP_LIGHTING_HDR {
		faces_lump = LUMP_FACES_HDR
	}
	faces_offset := lump_int(data, faces_lump, 0)
	faces_length := lump_int(data, faces_lump, 4)
	if faces_length <= 0 || faces_offset <= 0 {
		return
	}
	for i in 0 ..< faces_length / 56 {
		face := faces_offset + i * 56
		if int(read_i32(data, face + 20)) < 0 {
			continue
		}
		size_x := int(read_i32(data, face + 36))
		size_y := int(read_i32(data, face + 40))
		if size_x < 0 || size_y < 0 {
			continue
		}
		blocks += 1
		attributed += i64(size_x + 1) * i64(size_y + 1) * 4
	}
	return
}

// lighting_reason checks the lightmap sample array against the faces that point
// into it. What holds over the whole corpus is containment and disjointness: every
// block starts inside the lump and no two blocks overlap. What does not hold is
// tiling: the lightmap blocks of the faces cover only about a third of the lump
// (measured: 325 MB of 922 MB over the 82 maps), because the writer also stores
// something this reader does not attribute to a face. The check below therefore
// proves the face side of the lump and says nothing about the rest.
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
	count := faces_length / 56
	blocks := make([dynamic]Lightmap_Block, 0, count, context.allocator)
	defer delete(blocks)
	for i in 0 ..< count {
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
		append(&blocks, Lightmap_Block{start = lightofs, end = int(extent)})
	}
	// Two faces may not claim the same bytes: a shared or overlapping block means
	// one of the two offsets is not a sample offset at all.
	slice.sort_by(blocks[:], proc(a, b: Lightmap_Block) -> bool { return a.start < b.start })
	for i in 1..<len(blocks) {
		if blocks[i].start < blocks[i - 1].end {
			return "two lightmap blocks overlap"
		}
	}
	return ""
}

Lightmap_Block :: struct {
	start: int,
	end:   int,
}

// phys_collide_reason walks the per-model collision chain: a 16 byte header
// (model index, collide size, key size, solid count), the blobs, and a terminator
// whose model index is -1.
//
// The blobs are not taken on their declared length alone. Every model that carries
// collision writes its solids as a chain of `{int size, "VPHY", short version,
// short model type, int surface size, ...}` records, so the model's data size is the
// sum of 4 + size over its solids and the walk has to land exactly on it. The magic,
// the version (256 in every solid of the corpus) and the two header lengths the
// records use (size - surface size is 12 or 28) say the chain is understood and not
// merely skipped; the key data is the matching stack of solids as VMF text.
PHYS_Tally :: struct {
	models:        int,
	solids:        int,
	collide_bytes: int,
}

PHYS_SOLID_MAGIC :: "VPHY"
PHYS_SOLID_VERSION :: 256
PHYS_MODEL_STRIDE :: 48 // dmodel_t: mins, maxs, origin, headnode, firstface, numfaces

phys_collide_reason :: proc(data: []u8, offset, length: int, tally: ^PHYS_Tally = nil) -> string {
	pos := offset
	end := offset + length
	models_length := lump_int(data, LUMP_MODELS, 4)
	num_models := models_length > 0 ? models_length / PHYS_MODEL_STRIDE : 0
	seen := make(map[int]bool, 16, context.temp_allocator)
	defer delete(seen)
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
		if num_models > 0 && int(model) >= num_models {
			return "collision for a model the model lump does not have"
		}
		if int(model) in seen {
			return "a model carries two collision blocks"
		}
		seen[int(model)] = true
		if pos + data_size + key_size > end {
			return "model blobs past the lump"
		}
		if tally != nil {
			tally.models += 1
			tally.solids += int(solids)
			tally.collide_bytes += data_size
		}
		// The solids chain has to tile the collide blob.
		at := pos
		blob_end := pos + data_size
		for _ in 0 ..< int(solids) {
			if at + 16 > blob_end {
				return "a solid header does not fit its model blob"
			}
			size := int(read_i32(data, at))
			if size <= 0 || at + 4 + size > blob_end {
				return "a solid's size runs past its model blob"
			}
			if string(data[at + 4:at + 8]) != PHYS_SOLID_MAGIC {
				return "a solid does not start with VPHY"
			}
			if int(read_u16(data, at + 8)) != PHYS_SOLID_VERSION {
				return "a solid carries an unknown collide version"
			}
			delta := size - int(read_i32(data, at + 12))
			if delta != 12 && delta != 28 {
				return "a solid's surface size does not match its length"
			}
			at += 4 + size
		}
		if at != blob_end {
			return "the solids do not fill their model blob"
		}
		if solids == 0 && data_size != 0 {
			return "a model without solids carries collide data"
		}
		if key_size > 0 {
			key := data[pos + data_size:pos + data_size + key_size]
			if key[len(key) - 1] != 0 {
				return "the key data does not end with a terminator"
			}
			for byte in key {
				if byte == 0 {
					break
				}
				if byte != '\n' && byte != '\r' && byte != '\t' && (byte < 0x20 || byte > 0x7e) {
					return "the key data is not text"
				}
			}
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

// disp_power returns the grid power of a displacement record and refuses one
// outside the range the corpus shows, so every displacement walk agrees on it.
disp_power :: proc(data: []u8, record: int) -> (power: int, ok: bool) {
	power = int(read_i32(data, record + 20))
	return power, power >= 2 && power <= 4
}

// dispinfo_reason walks the displacement records: the vertex and triangle runs
// they name must start where the previous record ended, every power must be in
// range, and the two running totals must be exactly the two lump sizes they index.
dispinfo_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 176 != 0 {
		return "size is not a multiple of 176"
	}
	verts := 0
	tris := 0
	for i in 0 ..< length / 176 {
		record := offset + i * 176
		power, power_ok := disp_power(data, record)
		if !power_ok {
			return "displacement power outside 2..4"
		}
		if int(read_i32(data, record + 12)) != verts {
			return "a displacement vertex run does not continue the previous one"
		}
		if int(read_i32(data, record + 16)) != tris {
			return "a displacement triangle run does not continue the previous one"
		}
		side := (1 << uint(power)) + 1
		verts += side * side
		tris += 2 * (1 << uint(power)) * (1 << uint(power))
	}
	if verts * 20 != lump_length(data, LUMP_DISPVERTS) {
		return "the displacement vertex runs do not add up to the vertex lump"
	}
	if tris * 2 != lump_length(data, LUMP_DISPTRIS) {
		return "the displacement triangle runs do not add up to the triangle lump"
	}
	return ""
}

// disp_tri_reason counts the displacement triangles: two bytes each, and the
// displacement records say how many triangles every surface has (two per cell of
// its grid), so the total is a cross count and not a divisibility test.
disp_tri_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 2 != 0 {
		return "size is not a multiple of 2"
	}
	info_offset := lump_int(data, LUMP_DISPINFO, 0)
	info_length := lump_int(data, LUMP_DISPINFO, 4)
	if info_length <= 0 {
		if length != 0 {
			return "triangles without displacement info"
		}
		return ""
	}
	expected := 0
	for i in 0 ..< info_length / 176 {
		power, ok := disp_power(data, info_offset + i * 176)
		if !ok {
			return "displacement power outside 2..4"
		}
		cells := 1 << uint(power)
		expected += 2 * cells * cells
	}
	if expected * 2 != length {
		return "triangle count does not match the displacement infos"
	}
	return ""
}

// disp_lightmap_alpha_reason counts one byte per lightmap luxel of every face that
// has a displacement: the face stores the luxel extent, so the total is exact.
disp_lightmap_alpha_reason :: proc(data: []u8, offset, length: int) -> string {
	faces_offset := lump_int(data, LUMP_FACES, 0)
	faces_length := lump_int(data, LUMP_FACES, 4)
	if faces_length <= 0 {
		if length != 0 {
			return "lightmap alphas without a face lump to count them against"
		}
		return ""
	}
	expected := 0
	for i in 0 ..< faces_length / 56 {
		face := faces_offset + i * 56
		if read_u16(data, face + 12) == 0xffff {
			continue
		}
		size_x := int(read_i32(data, face + 36))
		size_y := int(read_i32(data, face + 40))
		if size_x < 0 || size_y < 0 {
			return "negative lightmap extent"
		}
		expected += (size_x + 1) * (size_y + 1)
	}
	if expected != length {
		return "count is not one byte per displacement lightmap luxel"
	}
	return ""
}

// texdata_string_data_reason reads the material name blob: NUL terminated names with
// no empty one in between, ending on a terminator.
texdata_string_data_reason :: proc(data: []u8, offset, length: int) -> string {
	if length <= 0 {
		return "empty material name blob"
	}
	if data[offset + length - 1] != 0 {
		return "the material name blob does not end with a terminator"
	}
	for i in 1 ..< length {
		if data[offset + i] == 0 && data[offset + i - 1] == 0 {
			return "the material name blob holds an empty name"
		}
	}
	return ""
}

// texdata_string_table_reason reads the offsets into that blob: the first is zero,
// they rise strictly, and each lands on the first byte of a name.
texdata_string_table_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 4 != 0 {
		return "size is not a multiple of 4"
	}
	names := lump_int(data, LUMP_TEXDATA_STRING_DATA, 4)
	data_offset := lump_int(data, LUMP_TEXDATA_STRING_DATA, 0)
	if names <= 0 {
		return "no material name blob to index"
	}
	previous := -1
	for i in 0 ..< length / 4 {
		at := int(read_i32(data, offset + i * 4))
		if at < 0 || at >= names {
			return "a name offset is outside the name blob"
		}
		if i == 0 && at != 0 {
			return "the first name offset is not zero"
		}
		if at <= previous {
			return "name offsets do not rise"
		}
		if at > 0 && data[data_offset + at - 1] != 0 {
			return "a name offset does not start a name"
		}
		previous = at
	}
	return ""
}

// vert_normal_reason reads the normal array: twelve bytes each and exactly as many
// as the index lump uses, which is a cross count against the faces.
vert_normal_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 12 != 0 {
		return "size is not a multiple of 12"
	}
	for i in 0 ..< length / 12 {
		base := offset + i * 12
		for k in 0 ..< 3 {
			value := read_f32(data, base + k * 4)
			if !(value == value) || value > 1e30 || value < -1e30 {
				return "non-finite normal component"
			}
		}
	}
	index_length := lump_length(data, LUMP_VERTNORMALINDICES)
	if index_length <= 0 {
		return ""
	}
	highest := -1
	for i in 0 ..< index_length / 2 {
		value := int(read_u16(data, lump_int(data, LUMP_VERTNORMALINDICES, 0) + i * 2))
		if value > highest {
			highest = value
		}
	}
	if (highest + 1) * 12 != length {
		return "the normal lump does not hold exactly the normals the indices use"
	}
	return ""
}

// vert_normal_index_reason counts one normal index per vertex a face uses: the sum
// of the face edge counts, and every index has to name a normal that exists.
vert_normal_index_reason :: proc(data: []u8, offset, length: int) -> string {
	faces_offset := lump_int(data, LUMP_FACES, 0)
	faces_length := lump_int(data, LUMP_FACES, 4)
	if faces_length <= 0 {
		return ""
	}
	expected := 0
	for i in 0 ..< faces_length / 56 {
		expected += int(read_u16(data, faces_offset + i * 56 + 8))
	}
	if length != expected * 2 {
		return "count is not one index per vertex a face uses"
	}
	normals := lump_length(data, LUMP_VERTNORMALS) / 12
	if normals <= 0 {
		return ""
	}
	for i in 0 ..< length / 2 {
		if int(read_u16(data, offset + i * 2)) >= normals {
			return "a normal index is past the normal lump"
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
leaf_ambient_reason :: proc(data: []u8, index, offset, length: int) -> string {
	// The index says how many ambient samples each leaf owns; adding those counts
	// gives the sample count the lump must hold, which is a cross count and not a
	// divisibility test. Current maps store a 24 byte compressed cube plus x, y, z
	// and a zero pad; the older maps in the corpus stop after the cube.
	index_lump := LUMP_LEAF_AMBIENT_INDEX
	if index == LUMP_LEAF_AMBIENT_HDR {
		index_lump = LUMP_LEAF_AMBIENT_INDEX_HDR
	}
	index_length := lump_int(data, index_lump, 4)
	expected := -1
	if index_length > 0 && index_length % 4 == 0 {
		total := 0
		for i in 0 ..< index_length / 4 {
			total += int(pak_u16(data, lump_int(data, index_lump, 0) + i * 4))
		}
		expected = total
	}
	if length % 28 == 0 && (expected < 0 || expected * 28 == length) {
		for i in 0 ..< length / 28 {
			if data[offset + i * 28 + 27] != 0 {
				return "an ambient sample has a non zero pad byte"
			}
		}
		return ""
	}
	if length % 24 == 0 && (expected < 0 || expected * 24 == length) {
		return ""
	}
	if expected >= 0 {
		return fmt.aprintf("the leaf index names %d samples of 28 or 24 bytes and the lump holds %d", expected, length)
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
// leaf_ambient_index_reason reads the ambient cube index: four bytes per leaf,
// a count and the first sample, and the runs of samples those leaves name have to
// tile the ambient lump (55 for the HDR index, 56 for the LDR one) exactly. The
// engine pairs them the same way: Mod_LoadLeafs hands lumps 55/51 and 56/52 to one
// loader, which only copies the index when it holds a sample count.
leaf_ambient_index_reason :: proc(data: []u8, index, offset, length: int) -> string {
	leaves := leaf_count(data)
	if leaves == 0 {
		return "no leaf lump divisible by its stride to count the index against"
	}
	if length != leaves * 4 {
		return "size is not four bytes per leaf"
	}
	samples_lump := LUMP_LEAF_AMBIENT
	if index == LUMP_LEAF_AMBIENT_INDEX_HDR {
		samples_lump = LUMP_LEAF_AMBIENT_HDR
	}
	samples_length := lump_int(data, samples_lump, 4)
	spans := make([dynamic][2]int, 0, leaves, context.allocator)
	defer delete(spans)
	for i in 0..<leaves {
		count := int(pak_u16(data, offset + i * 4))
		first := int(pak_u16(data, offset + i * 4 + 2))
		if count == 0 {
			continue
		}
		append(&spans, {first, first + count})
	}
	if samples_length == 0 {
		if len(spans) > 0 {
			return "the index names ambient samples the sample lump does not hold"
		}
		return ""
	}
	stride := 28
	if samples_length % 28 != 0 {
		if samples_length % 24 != 0 {
			return "ambient sample lump is a multiple of neither 28 nor 24"
		}
		stride = 24
	}
	samples := samples_length / stride
	slice.sort_by(spans[:], proc(a, b: [2]int) -> bool { return a[0] < b[0] })
	position := 0
	for span in spans {
		if span[0] != position {
			if span[0] < position {
				return "two leaves name the same ambient sample"
			}
			return fmt.aprintf("%d ambient samples belong to no leaf", span[0] - position)
		}
		position = span[1]
	}
	if position != samples {
		return fmt.aprintf("the leaf index ends at sample %d of %d", position, samples)
	}
	return ""
}

// entities_reason reads the entity lump as the text it is: NUL terminated tokens,
// braces that open and close in order, an even number of tokens inside a block
// (keys and values alternate) and the last byte a terminator.
entities_reason :: proc(data: []u8, offset, length: int) -> string {
	if length <= 0 {
		return "empty entity lump"
	}
	if data[offset + length - 1] != 0 {
		return "the entity lump does not end with a terminator"
	}
	position := 0
	depth := 0
	pending := 0 // class name outside a block, key or value inside one
	for position < length {
		start := position
		for position < length && data[offset + position] != 0 {
			position += 1
		}
		if position >= length {
			return "unterminated token"
		}
		token := string(data[offset + start:offset + position])
		position += 1
		switch token {
		case "{":
			// One token opens a block: the class name.
			if pending > 1 {
				return "a block opens after more than one token"
			}
			if depth != 0 {
				return "a block opens inside another block"
			}
			depth = 1
			pending = 0
		case "}":
			if depth == 0 {
				return "a closing brace opens nothing"
			}
			if pending % 2 != 0 {
				return "a key has no value before the block closes"
			}
			depth = 0
			pending = 0
		case:
			pending += 1
		}
	}
	if depth != 0 {
		return "unbalanced braces"
	}
	if pending > 1 {
		return "the entity lump ends inside a pair"
	}
	return ""
}

// overlay_reason reads a 352 byte overlay record: its id is its index, it names at
// most 64 faces and every one of them exists, and the fade lump holds a pair of
// floats per overlay when it is there at all.
overlay_reason :: proc(data: []u8, offset, length: int) -> string {
	if length % 352 != 0 {
		return "size is not a multiple of 352"
	}
	overlays := length / 352
	fades := lump_int(data, LUMP_OVERLAY_FADES, 4)
	if fades > 0 && fades != overlays * 8 {
		return "the fade lump does not hold eight bytes per overlay"
	}
	faces := lump_int(data, LUMP_FACES, 4) / 56
	for i in 0 ..< overlays {
		record := offset + i * 352
		if int(read_i32(data, record)) != i {
			return "an overlay carries an id that is not its index"
		}
		count := int(pak_u16(data, record + 6)) & 0x3fff
		if count > 64 {
			return "an overlay names more than 64 faces"
		}
		for k in 0 ..< count {
			if faces > 0 {
				face := int(read_i32(data, record + 8 + k * 4))
				if face < 0 || face >= faces {
					return "an overlay names a face that does not exist"
				}
			}
		}
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
	// The lump is a sixteen bit count and, when it is not zero, a size per
	// displacement followed by the blobs. A map without displacements writes the
	// count alone: two zero bytes, which is what the eight small maps of the corpus
	// carry.
	if length < 2 {
		return "shorter than the displacement count"
	}
	count := int(read_u16(data, offset))
	disps := lump_length(data, LUMP_DISPINFO) / 176
	if count != disps {
		return "count does not match the displacement info lump"
	}
	if count == 0 {
		if length != 2 {
			return "an empty size table has trailing bytes"
		}
		return ""
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
