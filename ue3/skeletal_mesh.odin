package ue3

import "core:fmt"
import "../diag"

// Sizes measured on CH_MNPCguard01_lobby (export 82 of
// Characters_Male_combocloth.ccpk) for package 576, licensee 5.
SKEL_BONE_SIZE :: 52
SKEL_SECTION_SIZE :: 10
SKEL_RIGID_VERTEX_SIZE :: 61
SKEL_SOFT_VERTEX_SIZE :: 68
SKEL_EDGE_SIZE :: 16
SKEL_NAME_INDEX_ENTRY :: 12

// USkeletalMesh (Engine/Src/UnSkeletalMesh.cpp) for the Vogster build.
//
// The reader walks the structure rather than the raw bytes, so it fails
// (instead of producing shifted data) on any version whose gates differ from
// the ones measured here: 493 <= package < 592 with licensee 5.
Skeletal_Mesh :: struct {
	bones:            int,
	lods:             int,
	sections:         int,
	section_triangles:  int, // triangles the sections of every LOD declare
	material_anomalies: int, // sections naming a material past the mesh's array
}

// read_i32_at reads a little-endian count that was skipped over.
read_i32_at :: proc(data: []u8, at: int) -> i32 {
	if at < 0 || at + 4 > len(data) {
		return 0
	}
	return i32(u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24)
}

// section_layout_ok checks the sections of one LOD against each other: the offset
// of a section's indices is three times the triangles before it (the sections tile
// the index buffer), the material index is inside the material array and every
// triangle count is positive. It is the cross-check that fixes the field order of a
// 10-byte record and, with it, that the index count can be predicted before it is
// read.
section_layout_ok :: proc(
	data: []u8,
	at: int,
	count: int,
	materials: i32,
	result: ^Skeletal_Mesh,
	d: ^diag.Diagnostics,
) -> bool {
	expected := 0
	for i in 0 ..< count {
		base := at + i * SKEL_SECTION_SIZE
		if base < 0 || base + SKEL_SECTION_SIZE > len(data) {
			diag.err(d, "ue3.skeletal-section-overrun", fmt.aprintf("section %d of %d does not fit", i, count))
			return false
		}
		material := int(u16(data[base]) | u16(data[base + 1]) << 8)
		chunk := int(u16(data[base + 2]) | u16(data[base + 3]) << 8)
		base_index := int(read_i32_at(data, base + 4))
		triangles := int(u16(data[base + 8]) | u16(data[base + 9]) << 8)
		if triangles <= 0 {
			diag.err(d, "ue3.skeletal-section-empty", fmt.aprintf("section %d of %d has %d triangles", i, count, triangles))
			return false
		}
		if base_index != expected {
			diag.err(d, "ue3.skeletal-section-offset",
				fmt.aprintf("section %d starts at index %d, the sections before it end at %d", i, base_index, expected))
			return false
		}
		// The material index of a section is inside the mesh's own material array in
		// every mesh but one in the corpus: CH_MNPCguard01_lobby has three sections
		// naming materials 0, 1 and 2 while its array holds two, so the index can
		// reach past the array it is written against. It is reported, not enforced,
		// because the offset, the triangle count and the index words below already
		// tie the record down.
		if materials > 0 && material >= int(materials) {
			result.material_anomalies += 1
		}
		_ = chunk
		expected += triangles * 3
	}
	result.section_triangles = expected / 3
	return true
}

read_skeletal_mesh :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Skeletal_Mesh, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	version := engine_version(&pkg.summary)
	licensee := licensee_version(&pkg.summary)
	if version < 493 || version >= 592 || licensee != 5 {
		diag.err(
			&d,
			"ue3.skeletal-version",
			fmt.aprintf("unsupported SkeletalMesh build %d/%d", version, licensee),
		)
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller: deleting them here and
		// again in the caller is a double free that kills the process.
		d = head_d
		return
	}
	defer delete(head_d.items)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	end := head.end_offset

	consumed :: proc(r: ^Reader, d: ^diag.Diagnostics, n: int, what: string) -> bool {
		if r.failed {
			diag.err(d, "ue3.truncated", r.message)
			return false
		}
		if n < 0 || n > r.limit - r.pos {
			diag.err(d, "ue3.skeletal-overrun", fmt.aprintf("%s does not fit (%d bytes)", what, n))
			return false
		}
		r.pos += n
		return true
	}
	count_ok :: proc(r: ^Reader, d: ^diag.Diagnostics, count: i32, max: i32, what: string) -> bool {
		if r.failed || count < 0 || count > max {
			diag.err(d, "ue3.skeletal-count", fmt.aprintf("bad %s count %d", what, count))
			return false
		}
		return true
	}
	array :: proc(r: ^Reader, d: ^diag.Diagnostics, elem: int, what: string) -> bool {
		count := read_i32(r)
		if !count_ok(r, d, count, 10_000_000, what) {
			return false
		}
		return consumed(r, d, int(count) * elem, what)
	}

	// Bounds (FBoxSphereBounds).
	if !consumed(&r, &d, 28, "bounds") {
		return
	}
	// Materials: TArray<UMaterialInterface*> as package indices.
	materials_at := r.pos
	if !array(&r, &d, 4, "materials") {
		return
	}
	material_count := read_i32_at(pkg.data, materials_at)
	// Origin, RotOrigin.
	if !consumed(&r, &d, 24, "origin") {
		return
	}
	// RefSkeleton: TArray<FMeshBone>.
	bones := read_i32(&r)
	if !count_ok(&r, &d, bones, 100_000, "bones") ||
	   !consumed(&r, &d, int(bones) * SKEL_BONE_SIZE, "skeleton") {
		return
	}
	result.bones = int(bones)
	// SkeletalDepth.
	if !consumed(&r, &d, 4, "skeletal-depth") {
		return
	}
	// Vogster byte, present only in this build.
	if !consumed(&r, &d, 1, "vogster-byte") {
		return
	}
	lods := read_i32(&r)
	if !count_ok(&r, &d, lods, 65_535, "LODModels") {
		return
	}
	result.lods = int(lods)

	for _ in 0 ..< int(lods) {
		sections := read_i32(&r)
		if !count_ok(&r, &d, sections, 1_000_000, "sections") ||
		   !consumed(&r, &d, int(sections) * SKEL_SECTION_SIZE, "sections") {
			return
		}
		// FSkelMeshSection as this build serializes it: material, chunk, the offset
		// of the section's indices and its triangle count. The sections tile the
		// LOD's index buffer, so the offset of each one is three times the triangles
		// before it and the total is the index count; reading them at 10 bytes with
		// any other layout breaks that identity on the first multi-section mesh.
		if !section_layout_ok(pkg.data, r.pos - int(sections) * SKEL_SECTION_SIZE, int(sections), material_count, &result, &d) {
			return
		}
		result.sections += int(sections)
		// MultiSizeIndexContainer: DataTypeSize then the index words.
		data_type := read_i32(&r)
		index_count := read_i32(&r)
		if i32(result.section_triangles) * 3 != index_count {
			diag.err(&d, "ue3.skeletal-index-count",
				fmt.aprintf("%d section triangle(s) against %d index word(s)", result.section_triangles, index_count))
			return
		}
		if !count_ok(&r, &d, index_count, 50_000_000, "indices") {
			return
		}
		index_size := 2 if data_type == 2 else 4
		if !consumed(&r, &d, int(index_count) * index_size, "indices") {
			return
		}
		// Legacy shadow indices, active bones, double-sided flags.
		if !array(&r, &d, 2, "shadow-indices") ||
		   !array(&r, &d, 2, "active-bones") ||
		   !array(&r, &d, 1, "shadow-double-sided") {
			return
		}
		// Chunks.
		chunks := read_i32(&r)
		if !count_ok(&r, &d, chunks, 1_000_000, "chunks") {
			return
		}
		for _ in 0 ..< int(chunks) {
			if !consumed(&r, &d, 4, "chunk-base") {
				return
			}
			rigid := read_i32(&r)
			if !count_ok(&r, &d, rigid, 10_000_000, "rigid-vertices") ||
			   !consumed(&r, &d, int(rigid) * SKEL_RIGID_VERTEX_SIZE, "rigid-vertices") {
				return
			}
			soft := read_i32(&r)
			if !count_ok(&r, &d, soft, 10_000_000, "soft-vertices") ||
			   !consumed(&r, &d, int(soft) * SKEL_SOFT_VERTEX_SIZE, "soft-vertices") {
				return
			}
			if !array(&r, &d, 2, "bone-map") ||
			   !consumed(&r, &d, 12, "chunk-counters") {
				return
			}
		}
		// Size, NumVertices.
		if !consumed(&r, &d, 8, "lod-size") {
			return
		}
		// Legacy edges.
		if !array(&r, &d, SKEL_EDGE_SIZE, "edges") {
			return
		}
		// RequiredBones.
		if !array(&r, &d, 1, "required-bones") {
			return
		}
		// RawPointIndices: FBulkData header, inline words.
		_ = read_u32(&r)
		_ = read_i32(&r)
		raw_size := read_i32(&r)
		_ = read_i32(&r)
		if !count_ok(&r, &d, raw_size, 50_000_000, "raw-point-indices") ||
		   !consumed(&r, &d, int(raw_size), "raw-point-indices") {
			return
		}
		// VertexBufferGPUSkin: precision flag, stride, count, data.
		_ = read_i32(&r) // bUseFullPrecisionUVs
		stride := read_i32(&r)
		vertex_count := read_i32(&r)
		if !count_ok(&r, &d, stride, 256, "vertex-stride") ||
		   !count_ok(&r, &d, vertex_count, 10_000_000, "vertices") ||
		   !consumed(&r, &d, int(stride) * int(vertex_count), "vertices") {
			return
		}
		// Trailing empty array (VertexInfluences / ColorVertexBuffer).
		if !consumed(&r, &d, 4, "lod-tail") {
			return
		}
	}

	// NameIndexMap: 52 entries of (FName, INT) observed.
	entries := read_i32(&r)
	if !count_ok(&r, &d, entries, 1_000_000, "name-index-map") ||
	   !consumed(&r, &d, int(entries) * SKEL_NAME_INDEX_ENTRY, "name-index-map") {
		return
	}
	// PerPolyBoneKDOPs: per bone the compact kDOP tree (a nodes bulk and a
	// triangle bulk) followed by the collision vertices (UnSkeletalMesh.h:4455,
	// UnkDOP.h:2178 and :3033).
	kdops := read_i32(&r)
	if !count_ok(&r, &d, kdops, 100_000, "per-poly-kdops") {
		return
	}
	for _ in 0 ..< int(kdops) {
		_ = skip_bulk(&r) // kDOP nodes
		_ = skip_bulk(&r) // kDOP triangles
		verts := read_i32(&r)
		if r.failed || !count_ok(&r, &d, verts, 1_000_000, "collision-verts") ||
		   !consumed(&r, &d, int(verts) * 12, "collision-verts") {
			return
		}
	}
	// BoneBreakNames from VER_ADDED_EXTRA_SKELMESH_VERTEX_INFLUENCE_MAPPING (609)
	// as a TArray of FName, and the per-name options from 694 (absent here).
	if version >= 609 {
		names := read_i32(&r)
		if !count_ok(&r, &d, names, 1_000_000, "bone-break-names") ||
		   !consumed(&r, &d, int(names) * 8, "bone-break-names") {
			return
		}
		if version >= 694 {
			options := read_i32(&r)
			if !count_ok(&r, &d, options, 1_000_000, "bone-break-options") ||
			   !consumed(&r, &d, int(options), "bone-break-options") {
				return
			}
		}
	}
	if r.pos != end {
		diag.err(
			&d,
			"ue3.skeletal-size-mismatch",
			fmt.aprintf("consumed %d of %d bytes", r.pos - int(e.serial_offset), e.serial_size),
		)
		return
	}
	return
}
