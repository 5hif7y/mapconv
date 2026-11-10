// Package bsp reads compiled Source 1 BSP files (version 20) and converts them
// into the canonical IR.
//
// A compiled BSP no longer stores the mapper's brushes for world geometry: the
// compiler cut the world along the BSP tree. The world brushes are therefore
// reconstructed from the tree (the method of ericw-tools' `bsputil --decompile`,
// see docs/formats/source-bsp.md), while brush entities keep their authored
// brushes from the brush lumps.
package bsp

import "core:fmt"
import "../diag"
import "../geom"

IDENT :: 0x50534256 // "VBSP"
HEADER_LUMPS :: 64
MIN_VERSION :: 19
VERSION :: 20

// Lump ids (Source 20). Only the lumps this adapter reads are listed.
LUMP_ENTITIES :: 0
LUMP_PLANES :: 1
LUMP_TEXDATA :: 2
LUMP_VERTEXES :: 3
LUMP_VISIBILITY :: 4
LUMP_NODES :: 5
LUMP_TEXINFO :: 6
LUMP_FACES :: 7
LUMP_LIGHTING :: 8
LUMP_LEAFS :: 10
LUMP_WORLDLIGHTS :: 15
LUMP_FACEIDS :: 11
LUMP_EDGES :: 12
LUMP_SURFEDGES :: 13
LUMP_MODELS :: 14
LUMP_LEAFS_FACES :: 16
LUMP_LEAFBRUSHES :: 17
LUMP_BRUSHES :: 18
LUMP_BRUSHSIDES :: 19
LUMP_AREAS :: 20
LUMP_AREA_PORTALS :: 21
LUMP_DISPINFO :: 26
LUMP_DISP_LIGHTMAP_SAMPLE_POSITIONS :: 34
LUMP_ORIGFACES :: 27
LUMP_PHYSDISP :: 28
LUMP_PHYSCOLLIDE :: 29
LUMP_VERTNORMALS :: 30
LUMP_VERTNORMALINDICES :: 31
LUMP_DISP_LIGHTMAP_ALPHAS :: 32
LUMP_DISPVERTS :: 33
LUMP_GAMELUMP :: 35
LUMP_PRIMITIVES :: 37
LUMP_LEAF_WATER_DATA :: 36
LUMP_CLIP_PORTAL_VERTS :: 41
LUMP_OVERLAYS :: 45
LUMP_LEAF_MIN_DIST_TO_WATER :: 46
LUMP_LIGHTMAP_PAGES :: 51
LUMP_LIGHTMAP_PAGE_INFOS :: 52
LUMP_FACE_MACRO_TEXTURE_INFO :: 47
LUMP_PRIMVERTS :: 38
LUMP_PRIMINDICES :: 39
LUMP_DISPTRIS :: 48
LUMP_LIGHTING_HDR :: 53
LUMP_WORLDLIGHTS_HDR :: 54
LUMP_MAP_FLAGS :: 59
LUMP_OVERLAY_FADES :: 60
LUMP_PHYSCOLLIDESURFACE :: 49
LUMP_LEAF_AMBIENT_HDR :: 55
LUMP_LEAF_AMBIENT :: 56
LUMP_FACES_HDR :: 58
LUMP_TEXDATA_STRING_DATA :: 43
LUMP_TEXDATA_STRING_TABLE :: 44

CONTENTS_EMPTY :: 0
CONTENTS_SOLID :: 1
CONTENTS_SKY :: 2
CONTENTS_ORIGIN :: 4
CONTENTS_LAVA :: 8
CONTENTS_SLIME :: 16
CONTENTS_WATER :: 32
CONTENTS_CLIP :: 64

Plane :: struct {
	normal: geom.Vec3,
	dist:   f64,
}

// Face_Info is the texture projection stored by a texinfo record. texdata is the
// index whose name comes from the string table.
Texinfo :: struct {
	u, v:      geom.Vec3,
	u_offset:  f64,
	v_offset:  f64,
	texdata:   int,
	flags:     i32,
}

Texdata :: struct {
	name:   string,
	width:  int,
	height: int,
}

Node :: struct {
	plane:     i32,
	children:  [2]i32, // negative values are -(leaf + 1)
	mins, maxs: [3]f64,
	first_face: int,
	num_faces:  int,
}

Leaf :: struct {
	contents:        i32,
	first_leaf_face: int,
	num_leaf_faces:  int,
	first_leaf_brush: int,
	num_leaf_brushes: int,
}

Face :: struct {
	plane:    int,
	side:     bool,
	first_edge: int,
	num_edges:  int,
	texinfo:    int,
	dispinfo:   int,
}

Model :: struct {
	mins, maxs: [3]f64,
	origin:     geom.Vec3,
	headnode:   i32,
	first_face: int,
	num_faces:  int,
}

Brush_Side :: struct {
	plane:   int,
	texinfo: int,
	dispinfo: int,
	bevel:   bool,
}

Brush :: struct {
	first_side: int,
	num_sides:  int,
	contents:   i32,
}

File :: struct {
	header:   [HEADER_LUMPS][2]int, // offset, length
	version:  int,
	planes:   []Plane,
	texinfo:  []Texinfo,
	texdata:  []Texdata,
	nodes:    []Node,
	leafs:    []Leaf,
	leaves_ok: bool,
	faces:    []Face,
	edges:    [][2]int,
	surfedges: []i32,
	vertexes: []geom.Vec3,
	models:   []Model,
	brushes:  []Brush,
	brushsides: []Brush_Side,
	leafbrushes: []int,
	entities: []u8,
	dispinfo_count: int,
}

Read_Error :: enum {
	None,
	Too_Short,
	Bad_Ident,
	Unsupported_Version,
	Truncated_Lump,
}

read :: proc(data: []u8, d: ^diag.Diagnostics, path: string) -> (File, Read_Error) {
	file: File
	if len(data) < 1036 {
		diag.err(d, "bsp.too-short", "file is smaller than a BSP header", path)
		return file, .Too_Short
	}
	ident := read_i32(data, 0)
	file.version = int(read_i32(data, 4))
	if ident != IDENT {
		diag.err(d, "bsp.bad-ident", fmt.aprintf("expected the VBSP signature, found 0x%X", u32(ident)), path)
		return file, .Bad_Ident
	}
	if file.version < MIN_VERSION || file.version > VERSION {
		diag.err(
			d,
			"bsp.unsupported-version",
			fmt.aprintf(
				"BSP version %d is not supported; this adapter reads %d..%d (Source 1)",
				file.version,
				MIN_VERSION,
				VERSION,
			),
			path,
		)
		return file, .Unsupported_Version
	}
	for i in 0 ..< HEADER_LUMPS {
		base := 8 + i * 16
		offset := int(read_i32(data, base))
		length := int(read_i32(data, base + 4))
		if offset < 0 || length < 0 || offset + length > len(data) {
			if length != 0 {
				diag.warn(d, "bsp.lump-out-of-range", fmt.aprintf("lump %d lies outside the file and was skipped", i), path)
			}
			file.header[i] = {0, 0}
			continue
		}
		file.header[i] = {offset, length}
	}

	// Planes.
	{
		lump := file.header[LUMP_PLANES]
		count := lump[1] / 20
		file.planes = make([]Plane, count)
		for i in 0 ..< count {
			base := lump[0] + i * 20
			file.planes[i] = {
				normal = geom.vec3(
					f64(read_f32(data, base)),
					f64(read_f32(data, base + 4)),
					f64(read_f32(data, base + 8)),
				),
				dist = f64(read_f32(data, base + 12)),
			}
		}
	}

	// Texture names: string table -> string data.
	string_data := file.header[LUMP_TEXDATA_STRING_DATA]
	string_table := file.header[LUMP_TEXDATA_STRING_TABLE]
	texdata_lump := file.header[LUMP_TEXDATA]
	{
		count := texdata_lump[1] / 32
		file.texdata = make([]Texdata, count)
		for i in 0 ..< count {
			base := texdata_lump[0] + i * 32
			name_index := int(read_i32(data, base + 12))
			name := ""
			if string_table[1] >= 4 && name_index >= 0 && name_index * 4 + 4 <= string_table[1] {
				offset := int(read_i32(data, string_table[0] + name_index * 4))
				if offset >= 0 && offset < string_data[1] {
					start := string_data[0] + offset
					end := start
					limit := string_data[0] + string_data[1]
					for end < limit && data[end] != 0 {
						end += 1
					}
					name = string(data[start:end])
				}
			}
			file.texdata[i] = {
				name   = name,
				width  = int(read_i32(data, base + 16)),
				height = int(read_i32(data, base + 20)),
			}
		}
	}

	// Texinfo: two texture axes plus the texdata index.
	{
		lump := file.header[LUMP_TEXINFO]
		count := lump[1] / 72
		file.texinfo = make([]Texinfo, count)
		for i in 0 ..< count {
			base := lump[0] + i * 72
			file.texinfo[i] = {
				u         = geom.vec3(f64(read_f32(data, base)), f64(read_f32(data, base + 4)), f64(read_f32(data, base + 8))),
				u_offset  = f64(read_f32(data, base + 12)),
				v         = geom.vec3(f64(read_f32(data, base + 16)), f64(read_f32(data, base + 20)), f64(read_f32(data, base + 24))),
				v_offset  = f64(read_f32(data, base + 28)),
				flags     = read_i32(data, base + 64),
				texdata   = int(read_i32(data, base + 68)),
			}
		}
	}

	// Vertices, edges, surfedges: face windings.
	{
		lump := file.header[LUMP_VERTEXES]
		count := lump[1] / 12
		file.vertexes = make([]geom.Vec3, count)
		for i in 0 ..< count {
			base := lump[0] + i * 12
			file.vertexes[i] = geom.vec3(
				f64(read_f32(data, base)),
				f64(read_f32(data, base + 4)),
				f64(read_f32(data, base + 8)),
			)
		}
	}
	{
		lump := file.header[LUMP_EDGES]
		count := lump[1] / 4
		file.edges = make([][2]int, count)
		for i in 0 ..< count {
			base := lump[0] + i * 4
			file.edges[i] = {int(read_u16(data, base)), int(read_u16(data, base + 2))}
		}
	}
	{
		lump := file.header[LUMP_SURFEDGES]
		count := lump[1] / 4
		file.surfedges = make([]i32, count)
		for i in 0 ..< count {
			file.surfedges[i] = read_i32(data, lump[0] + i * 4)
		}
	}

	// BSP tree.
	{
		lump := file.header[LUMP_NODES]
		count := lump[1] / 32
		file.nodes = make([]Node, count)
		for i in 0 ..< count {
			base := lump[0] + i * 32
			node := Node {
				plane     = read_i32(data, base),
				children  = {read_i32(data, base + 4), read_i32(data, base + 8)},
				first_face = int(read_u16(data, base + 24)),
				num_faces  = int(read_u16(data, base + 26)),
			}
			for k in 0 ..< 3 {
				node.mins[k] = f64(read_i16(data, base + 12 + k * 2))
				node.maxs[k] = f64(read_i16(data, base + 18 + k * 2))
			}
			file.nodes[i] = node
		}
	}
	{
		lump := file.header[LUMP_LEAFS]
		count := lump[1] / 32
		file.leafs = make([]Leaf, count)
		for i in 0 ..< count {
			base := lump[0] + i * 32
			file.leafs[i] = Leaf {
				contents         = read_i32(data, base),
				first_leaf_face  = int(read_u16(data, base + 20)),
				num_leaf_faces   = int(read_u16(data, base + 22)),
				first_leaf_brush = int(read_u16(data, base + 24)),
				num_leaf_brushes = int(read_u16(data, base + 26)),
			}
		}
		file.leaves_ok = count > 0
	}
	{
		lump := file.header[LUMP_LEAFBRUSHES]
		count := lump[1] / 2
		file.leafbrushes = make([]int, count)
		for i in 0 ..< count {
			file.leafbrushes[i] = int(read_u16(data, lump[0] + i * 2))
		}
	}
	{
		lump := file.header[LUMP_FACES]
		count := lump[1] / 56
		file.faces = make([]Face, count)
		for i in 0 ..< count {
			base := lump[0] + i * 56
			file.faces[i] = Face {
				plane      = int(read_u16(data, base)),
				side       = data[base + 2] != 0,
				first_edge = int(read_i32(data, base + 4)),
				num_edges  = int(read_i16(data, base + 8)),
				texinfo    = int(read_i16(data, base + 10)),
				dispinfo   = int(read_i16(data, base + 12)),
			}
		}
	}

	// Models and brushes.
	{
		lump := file.header[LUMP_MODELS]
		count := lump[1] / 48
		file.models = make([]Model, count)
		for i in 0 ..< count {
			base := lump[0] + i * 48
			model := Model {
				headnode   = read_i32(data, base + 36),
				first_face = int(read_i32(data, base + 40)),
				num_faces  = int(read_i32(data, base + 44)),
			}
			mins := [3]f64{0, 0, 0}
			maxs := [3]f64{0, 0, 0}
			origin := [3]f64{0, 0, 0}
			for k in 0 ..< 3 {
				mins[k] = f64(read_f32(data, base + k * 4))
				maxs[k] = f64(read_f32(data, base + 12 + k * 4))
				origin[k] = f64(read_f32(data, base + 24 + k * 4))
			}
			model.mins = mins
			model.maxs = maxs
			model.origin = geom.Vec3{origin[0], origin[1], origin[2]}
			file.models[i] = model
		}
	}
	{
		lump := file.header[LUMP_BRUSHES]
		count := lump[1] / 12
		file.brushes = make([]Brush, count)
		for i in 0 ..< count {
			base := lump[0] + i * 12
			file.brushes[i] = Brush {
				first_side = int(read_i32(data, base)),
				num_sides  = int(read_i32(data, base + 4)),
				contents   = read_i32(data, base + 8),
			}
		}
	}
	{
		lump := file.header[LUMP_BRUSHSIDES]
		count := lump[1] / 8
		file.brushsides = make([]Brush_Side, count)
		for i in 0 ..< count {
			base := lump[0] + i * 8
			file.brushsides[i] = Brush_Side {
				plane    = int(read_u16(data, base)),
				texinfo  = int(read_i16(data, base + 2)),
				dispinfo = int(read_i16(data, base + 4)),
				bevel    = read_i16(data, base + 6) != 0,
			}
		}
	}

	{
		lump := file.header[LUMP_ENTITIES]
		if lump[1] > 0 {
			file.entities = data[lump[0]:lump[0] + lump[1]]
		}
	}
	{
		lump := file.header[LUMP_DISPINFO]
		file.dispinfo_count = lump[1] / 176
	}

	diag.info(
		d,
		"bsp.header",
		fmt.aprintf(
			"Source BSP %d: %d planes, %d nodes, %d leaves, %d faces, %d brushes, %d brush sides, %d texinfo",
			file.version,
			len(file.planes),
			len(file.nodes),
			len(file.leafs),
			len(file.faces),
			len(file.brushes),
			len(file.brushsides),
			len(file.texinfo),
		),
		path,
	)
	return file, .None
}

// texinfo_of resolves the material name and projection of a texinfo index.
texinfo_of :: proc(f: ^File, index: int) -> (material: string, used: bool) {
	if index < 0 || index >= len(f.texinfo) {
		return "", false
	}
	texdata_index := f.texinfo[index].texdata
	if texdata_index < 0 || texdata_index >= len(f.texdata) {
		return "", true
	}
	return f.texdata[texdata_index].name, true
}

// face_winding builds the polygon of a face from the surfedge list and orientates
// it counter-clockwise around the face normal.
face_winding :: proc(f: ^File, face: Face) -> (poly: [dynamic]geom.Vec3, normal: geom.Vec3, ok: bool) {
	poly = make([dynamic]geom.Vec3, 0, max(face.num_edges, 3))
	if face.plane < 0 || face.plane >= len(f.planes) {
		return poly, {}, false
	}
	plane := f.planes[face.plane]
	n := plane.normal
	if face.side {
		n = geom.neg(n)
	}
	for i in 0 ..< face.num_edges {
		edge_slot := face.first_edge + i
		if edge_slot < 0 || edge_slot >= len(f.surfedges) {
			return poly, n, false
		}
		e := int(f.surfedges[edge_slot])
		edge_index := e if e >= 0 else -e
		if edge_index < 0 || edge_index >= len(f.edges) {
			return poly, n, false
		}
		edge := f.edges[edge_index]
		vertex_index := edge[0] if e >= 0 else edge[1]
		if vertex_index < 0 || vertex_index >= len(f.vertexes) {
			return poly, n, false
		}
		append(&poly, f.vertexes[vertex_index])
	}
	if len(poly) < 3 {
		return poly, n, false
	}
	geom.orient_winding(poly[:], n)
	return poly, n, true
}

// model_brushes collects the authored brushes that belong to a model by walking
// its subtree and unioning the brushes of its leaves.
model_brushes :: proc(f: ^File, model: Model, out: ^[dynamic]int) {
	seen := make(map[int]bool, 64)
	defer delete(seen)
	stack := make([dynamic]i32, 0, 128)
	defer delete(stack)
	append(&stack, model.headnode)
	guard := 0
	for len(stack) > 0 {
		guard += 1
		if guard > 1 << 20 {
			break
		}
		index := pop(&stack)
		if index >= 0 {
			if int(index) >= len(f.nodes) {
				continue
			}
			node := f.nodes[index]
			append(&stack, node.children[0])
			append(&stack, node.children[1])
			continue
		}
		leaf_index := int(-1 - index)
		if leaf_index < 0 || leaf_index >= len(f.leafs) {
			continue
		}
		leaf := f.leafs[leaf_index]
		for i in 0 ..< leaf.num_leaf_brushes {
			slot := leaf.first_leaf_brush + i
			if slot < 0 || slot >= len(f.leafbrushes) {
				break
			}
			brush_index := f.leafbrushes[slot]
			if brush_index < 0 || brush_index >= len(f.brushes) {
				continue
			}
			if !seen[brush_index] {
				seen[brush_index] = true
				append(out, brush_index)
			}
		}
	}
}

read_i16 :: proc(data: []u8, offset: int) -> i16 {
	if offset < 0 || offset + 2 > len(data) {
		return 0
	}
	value := i16(data[offset]) | i16(data[offset + 1]) << 8
	return value
}

read_u16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(read_i16(data, offset))
}

read_i32 :: proc(data: []u8, offset: int) -> i32 {
	if offset < 0 || offset + 4 > len(data) {
		return 0
	}
	return (
		i32(data[offset]) |
		i32(data[offset + 1]) << 8 |
		i32(data[offset + 2]) << 16 |
		i32(data[offset + 3]) << 24
	)
}

read_f32 :: proc(data: []u8, offset: int) -> f32 {
	return transmute(f32)read_i32(data, offset)
}
