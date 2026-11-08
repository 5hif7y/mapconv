package ue3

import "core:fmt"
import "../diag"

// UStaticMeshComponent::Serialize (Engine/Src/UnStaticMesh.cpp:4875) for
// package version 576:
//
//	LODData: TArray<FStaticMeshComponentLODInfo>
//
// with FStaticMeshComponentLODInfo (Engine/Inc/UnStaticMesh.h:1733):
//
//	ShadowMaps          TArray<UShadowMap2D*>      count + refs × 4
//	ShadowVertexBuffers TArray<UShadowMap1D*>      count + refs × 4
//	LightMap            DWORD type                0 none, 1 LMT_1D, 2 LMT_2D
//
// For LMT_2D the legacy branch (< VER_MAXCOMPONENT_LIGHTMAP_ENCODING, 624)
// writes the light GUIDs, four (texture ref, FVector) pairs and two FVector2D
// bounds. The INT dummy that follows LODData in later versions is gated at
// VER_PRESERVE_SMC_VERT_COLORS (801), so it is absent in 576.
Static_Mesh_Component :: struct {
	lods:      int,
	lightmaps: int,
}

read_static_mesh_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Static_Mesh_Component, d: diag.Diagnostics) {
	d = diag.init()
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
	version := engine_version(&pkg.summary)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	skip_bulk :: proc(r: ^Reader) -> bool {
		flags := read_u32(r)
		count := read_i32(r)
		size := read_i32(r)
		offset := read_i32(r)
		if r.failed {
			return false
		}
		if size < 0 {
			// unused placeholder: no data, dimensions/flags still follow
			if flags & 0x20 != 0 && size == -1 {
				return true
			}
			return false
		}
		if flags & 0x01 != 0 {
			return true // payload lives in a separate file
		}
		if i64(size) > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(size)
		_ = count
		_ = offset
		return true
	}
	refs :: proc(r: ^Reader) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 100_000 {
			return false
		}
		if i64(count) * 4 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(count) * 4
		return true
	}

	lods := read_i32(&r)
	if r.failed || lods < 0 || lods > 16 {
		diag.err(&d, "ue3.bad-smc", fmt.aprintf("implausible LOD count %d", lods))
		return
	}
	result.lods = int(lods)
	for _ in 0 ..< int(lods) {
		if !refs(&r) || !refs(&r) {
			diag.err(&d, "ue3.bad-smc", "shadow map arrays did not parse")
			return
		}
		lightmap_type := read_u32(&r)
		if r.failed {
			diag.err(&d, "ue3.bad-smc", "light map type did not parse")
			return
		}
		switch lightmap_type {
		case 0:
			// no light map
		case 2:
			guids := read_i32(&r)
			if r.failed || guids < 0 || guids > 1_000_000 {
				diag.err(&d, "ue3.bad-smc", "light GUID count did not parse")
				return
			}
			if i64(guids) * 16 > i64(r.limit - r.pos) {
				diag.err(&d, "ue3.bad-smc", "light GUIDs overrun the export")
				return
			}
			r.pos += int(guids) * 16
			pairs := 3
			if version < 624 {
				pairs = 4
			}
			if i64(pairs) * 16 + 16 > i64(r.limit - r.pos) {
				diag.err(&d, "ue3.bad-smc", "light map coefficients overrun the export")
				return
			}
			r.pos += pairs * 16 // ref + FVector (serialized as 12 bytes)
			r.pos += 16 // CoordinateScale + CoordinateBias (FVector2D each)
			result.lightmaps += 1
		case 1:
			// FLightMap1D: GUIDs, owner reference, the directional sample bulk,
			// the legacy scale vectors and the simple sample bulk.
			guids := read_i32(&r)
			if r.failed || guids < 0 || guids > 1_000_000 {
				diag.err(&d, "ue3.bad-smc", "light GUID count did not parse")
				return
			}
			if i64(guids) * 16 + 4 > i64(r.limit - r.pos) {
				diag.err(&d, "ue3.bad-smc", "light GUIDs overrun the export")
				return
			}
			r.pos += int(guids) * 16
			r.pos += 4 // Owner
			if !skip_bulk(&r) {
				diag.err(&d, "ue3.bad-smc", "directional samples did not parse")
				return
			}
			vectors := 3
			if version < 624 {
				vectors = 4
			}
			if i64(vectors) * 12 > i64(r.limit - r.pos) {
				diag.err(&d, "ue3.bad-smc", "light map scale vectors overrun the export")
				return
			}
			r.pos += vectors * 12
			if !skip_bulk(&r) {
				diag.err(&d, "ue3.bad-smc", "simple samples did not parse")
				return
			}
			result.lightmaps += 1
		case:
			diag.err(&d, "ue3.smc-lightmap", fmt.aprintf("unsupported light map type %d", lightmap_type))
			return
		}
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.smc-layout", fmt.aprintf("UStaticMeshComponent consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
