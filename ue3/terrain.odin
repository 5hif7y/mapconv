// UTerrainComponent: the terrain collision payload.
//
// UTerrainComponent::Serialize (Engine/Src/UnTerrain.cpp:4291) writes, after
// Super and the tag stream:
//
//	CollisionVertices   TArray<FVector>             count and twelve bytes each
//	BVTree              FTerrainBVTree              count and 37 byte nodes
//	PatchBounds         TArray<FTerrainPatchBounds> count and twelve bytes each
//	LightMap            FLightMapSerializeHelper    type and light map data
//	BatchMaterials      CountBytes                  one word
//
// A node (Engine/Inc/UnTerrainBVTree.h:228) is an FBox, which serializes as six
// floats plus the IsValid byte (UnMath.h:2317), a UBOOL leaf flag and the eight
// byte union of child indices or sub region. The arrays are checked against each
// other and against the export end: every one of the eight components of
// industrial02 leaves exactly 104 bytes for the light map helper, so the reader
// credits the arrays and stops there instead of claiming the whole export.
package ue3

import "core:fmt"
import "core:math"
import "../diag"

TERRAIN_NODE_BYTES :: 37
TERRAIN_TAIL_BYTES :: 104

Terrain_Component :: struct {
	export_index:     int,
	collision_verts:  int,
	nodes:            int,
	patch_bounds:     int,
	tail_bytes:       int,
}

read_terrain_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (terrain: Terrain_Component, d: diag.Diagnostics) {
	d = diag.init()
	terrain.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	defer delete(head_d.items)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	count := read_i32(&r)
	if r.failed || count < 0 || count > 1_000_000 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible collision vertex count %d", count))
		return
	}
	for i in 0 ..< int(count) {
		for _ in 0 ..< 3 {
			value := read_f32(&r)
			if !(value == value) || math.abs(value) > 1e12 {
				diag.err(&d, "ue3.bad-terrain", fmt.aprintf("collision vertex %d holds a non-finite value", i))
				return
			}
		}
	}
	terrain.collision_verts = int(count)

	nodes := read_i32(&r)
	if r.failed || nodes < 0 || nodes > 1_000_000 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible node count %d", nodes))
		return
	}
	for i in 0 ..< int(nodes) {
		for _ in 0 ..< 6 {
			value := read_f32(&r)
			if !(value == value) || math.abs(value) > 1e12 {
				diag.err(&d, "ue3.bad-terrain", fmt.aprintf("node %d holds a non-finite bound", i))
				return
			}
		}
		is_valid := read_u8(&r)
		if is_valid > 1 {
			diag.err(&d, "ue3.bad-terrain", fmt.aprintf("node %d has an invalid box flag %d", i, is_valid))
			return
		}
		is_leaf := read_i32(&r)
		if is_leaf != 0 && is_leaf != 1 {
			diag.err(&d, "ue3.bad-terrain", fmt.aprintf("node %d has a non boolean leaf flag %d", i, is_leaf))
			return
		}
		for _ in 0 ..< 4 {
			_ = read_u16(&r)
		}
	}
	terrain.nodes = int(nodes)

	bounds := read_i32(&r)
	if r.failed || bounds < 0 || bounds > 1_000_000 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible patch bound count %d", bounds))
		return
	}
	for i in 0 ..< int(bounds) {
		for _ in 0 ..< 3 {
			value := read_f32(&r)
			if !(value == value) || math.abs(value) > 1e12 {
				diag.err(&d, "ue3.bad-terrain", fmt.aprintf("patch bound %d holds a non-finite value", i))
				return
			}
		}
	}
	terrain.patch_bounds = int(bounds)

	left := head.end_offset - r.pos
	if left != TERRAIN_TAIL_BYTES {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("arrays leave %d bytes, expected the %d byte light map block", left, TERRAIN_TAIL_BYTES))
		return
	}
	light_map_type := read_i32(&r)
	if light_map_type != 2 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("unexpected light map type %d", light_map_type))
		return
	}
	// FLightMap::Serialize writes the light case guids (UnLightMap.cpp:75) and
	// FLightMap2D continues with one texture reference and one scale vector per
	// stored coefficient plus the coordinate transform (UnLightMap.cpp:1902).
	// This build stores four coefficients, so the block is: type, guid count and
	// guid, four {reference, three floats}, then sixteen bytes of coordinates.
	guids := read_i32(&r)
	if r.failed || guids < 0 || guids > 16 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible light guid count %d", guids))
		return
	}
	for _ in 0 ..< int(guids) * 4 {
		_ = read_i32(&r)
	}
	for coefficient in 0 ..< 4 {
		reference := read_i32(&r)
		if r.failed || !valid_object_reference(pkg, reference) {
			diag.err(&d, "ue3.bad-terrain", fmt.aprintf("light map coefficient %d points at %d", coefficient, reference))
			return
		}
		for _ in 0 ..< 3 {
			value := read_f32(&r)
			if !(value == value) {
				diag.err(&d, "ue3.bad-terrain", fmt.aprintf("light map coefficient %d holds a non-finite scale", coefficient))
				return
			}
		}
	}
	for _ in 0 ..< 4 {
		value := read_f32(&r)
		if !(value == value) {
			diag.err(&d, "ue3.bad-terrain", "non-finite light map coordinate")
			return
		}
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("light map block consumed %d of %d bytes", r.pos - (head.end_offset - left), left))
		return
	}
	terrain.tail_bytes = 0
	return
}

// FTerrainMaterialResource: the cooked material of a terrain, which is what the
// ATerrain export carries after its height field.
//
// operator<< (Engine/Src/UnTerrainRender.cpp:787) calls R.Serialize, which is
// FMaterialResource::Serialize -> FMaterial::Serialize, then writes the terrain
// reference, the layer mask and the material ids. Three fields of the class are
// gated above package version 576 and are therefore absent here:
// LightingGuid (VER_INTEGRATED_LIGHTMASS 600) is regenerated on load,
// bEnableSpecular (VER_TERRAIN_SPECULAR_FIX 815) is not written and
// BlendModeOverrideValue (VER_MATERIAL_BLEND_OVERRIDE 853) never reaches disk.
//
// The mask is FTerrainMaterialMask::operator<< (Engine/Inc/UnTerrain.h:90): a bit
// count and a 64 bit mask. The ids are an array of sixteen byte GUIDs.
Terrain_Material_Resource :: struct {
	terrain:     i32,
	layer_bits:  i32,
	material_ids: int,
	end_offset:   int,
}

read_terrain_material_resource :: proc(
	r: ^Reader,
	pkg: ^Package,
	version: i32,
) -> (resource: Terrain_Material_Resource, ok: bool) {
	scratch: Material_Body
	if !parse_material_resource(r, pkg, version, &scratch) {
		return resource, false
	}
	if r.limit - r.pos < 20 {
		r.pos = r.limit
		return resource, false
	}
	resource.terrain = read_i32(r)
	resource.layer_bits = read_i32(r)
	_ = read_u64(r) // the mask itself
	if r.failed || !valid_object_reference(pkg, resource.terrain) {
		return resource, false
	}
	// A terrain has at most 64 layers, one bit each.
	if resource.layer_bits < 0 || resource.layer_bits > 64 {
		return resource, false
	}
	count := read_i32(r)
	if r.failed || count < 0 || i64(count) * 16 > i64(r.limit - r.pos) {
		return resource, false
	}
	r.pos += int(count) * 16
	resource.material_ids = int(count)
	resource.end_offset = r.pos
	return resource, true
}

// ATerrain::Serialize (Engine/Src/UnTerrain.cpp:2055) for package version 576:
// the height field arrays, the weighted texture maps, the cached material
// resources of the single terrain quality level, the legacy shader model 2 copy
// that was still written below 711, and the collision displacements that were
// written from 504 until 713.
read_terrain :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (terrain: Terrain_Component, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	head, head_d := read_object_head(pkg, pkg.exports[export_index], allocator, export_index)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	delete(head_d.items)
	version := engine_version(&pkg.summary)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	// Heights: one word each. InfoData: one byte each. They have to agree.
	heights := read_i32(&r)
	if r.failed || heights < 0 || i64(heights) * 2 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible height count %d", heights))
		return
	}
	r.pos += int(heights) * 2
	info := read_i32(&r)
	if r.failed || info != heights {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("info count %d does not match %d heights", info, heights))
		return
	}
	r.pos += int(info)

	// AlphaMaps: each one is a mask (twelve bytes) and a byte per height.
	alpha := read_i32(&r)
	if r.failed || alpha < 0 || alpha > 1_000_000 {
		diag.err(&d, "ue3.bad-terrain", "implausible alpha map count")
		return
	}
	for _ in 0 ..< int(alpha) {
		if r.limit - r.pos < 12 {
			diag.err(&d, "ue3.bad-terrain", "an alpha map header overruns the export")
			return
		}
		r.pos += 12 + int(heights)
	}

	// WeightedTextureMaps: object references.
	weighted := read_i32(&r)
	if r.failed || weighted < 0 || i64(weighted) * 4 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible weighted map count %d", weighted))
		return
	}
	for _ in 0 ..< int(weighted) {
		value := read_i32(&r)
		if r.failed || !valid_object_reference(pkg, value) {
			diag.err(&d, "ue3.bad-terrain", "a weighted texture map is not a reference")
			return
		}
	}

	cached := read_i32(&r)
	if r.failed || cached < 0 || cached > 64 {
		diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible cached material count %d", cached))
		return
	}
	for _ in 0 ..< int(cached) {
		_, ok := read_terrain_material_resource(&r, pkg, version)
		if !ok {
			diag.err(&d, "ue3.bad-terrain", fmt.aprintf("a cached material did not parse at %d", r.pos))
			return
		}
	}

	if version < 711 {
		legacy := read_i32(&r)
		if r.failed || legacy < 0 || legacy > 64 {
			diag.err(&d, "ue3.bad-terrain", fmt.aprintf("implausible legacy material count %d", legacy))
			return
		}
		for _ in 0 ..< int(legacy) {
			_, ok := read_terrain_material_resource(&r, pkg, version)
			if !ok {
				diag.err(&d, "ue3.bad-terrain", "a legacy material did not parse")
				return
			}
		}
	}

	if version >= 504 && version < 713 {
		displacements := read_i32(&r)
		if r.failed || displacements < 0 || i64(displacements) > i64(r.limit - r.pos) {
			diag.err(&d, "ue3.bad-terrain", "implausible displacement count")
			return
		}
		r.pos += int(displacements)
		if r.limit - r.pos < 4 {
			diag.err(&d, "ue3.bad-terrain", "the collision displacement limit is missing")
			return
		}
		r.pos += 4
	}

	if r.pos != head.end_offset {
		diag.err(
			&d,
			"ue3.terrain-end-mismatch",
			fmt.aprintf("the terrain ends at %d but the export ends at %d", r.pos, head.end_offset),
		)
		return
	}
	terrain.collision_verts = int(heights)
	return
}
