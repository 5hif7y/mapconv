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
	terrain.tail_bytes = left
	return
}
