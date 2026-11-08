package ue3

import "core:fmt"
import "../diag"

// UModelComponent::Serialize (Engine/Src/UnModelComponent.cpp:159):
//
//	Model (reference), ZoneIndex (INT), Elements (TIndirectArray<FModelElement>),
//	ComponentIndex (WORD), Nodes (TArray<WORD>)
//
// and FModelElement (Engine/Src/UnModelComponent.cpp:18):
//
//	LightMap, Component, Material, Nodes, ShadowMaps, IrrelevantLights
//
// The light map is the same reference form used by the static mesh component,
// so the legacy 1D/2D layouts are shared with it.
Model_Component :: struct {
	elements: int,
}

skip_lightmap_ref :: proc(r: ^Reader, version: i32) -> bool {
	kind := read_u32(r)
	if r.failed {
		return false
	}
	skip_bulk :: proc(r: ^Reader) -> bool {
		flags := read_u32(r)
		count := read_i32(r)
		size := read_i32(r)
		_ = read_i32(r) // offset
		if r.failed {
			return false
		}
		if size < 0 {
			return flags & 0x20 != 0 && size == -1
		}
		if flags & 0x01 != 0 {
			return true
		}
		if i64(size) > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(size)
		_ = count
		return true
	}
	switch kind {
	case 0:
		return true
	case 2:
		guids := read_i32(r)
		if r.failed || guids < 0 || guids > 1_000_000 || i64(guids) * 16 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(guids) * 16
		pairs := 3
		if version < 624 {
			pairs = 4
		}
		if i64(pairs) * 16 + 16 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += pairs * 16 + 16
		return true
	case 1:
		guids := read_i32(r)
		if r.failed || guids < 0 || guids > 1_000_000 || i64(guids) * 16 + 4 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(guids) * 16 + 4
		if !skip_bulk(r) {
			return false
		}
		vectors := 3
		if version < 624 {
			vectors = 4
		}
		if i64(vectors) * 12 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += vectors * 12
		return skip_bulk(r)
	}
	return false
}

read_model_component :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Model_Component, d: diag.Diagnostics) {
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

	skip_words :: proc(r: ^Reader) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 5_000_000 {
			return false
		}
		if i64(count) * 2 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(count) * 2
		return true
	}
	skip_refs :: proc(r: ^Reader) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 1_000_000 {
			return false
		}
		if i64(count) * 4 > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(count) * 4
		return true
	}

	r.pos += 4 // Model
	_ = read_i32(&r) // ZoneIndex
	elements := read_i32(&r)
	if r.failed || elements < 0 || elements > 100_000 {
		diag.err(&d, "ue3.bad-model-component", fmt.aprintf("implausible element count %d", elements))
		return
	}
	for _ in 0 ..< int(elements) {
		if !skip_lightmap_ref(&r, version) {
			diag.err(&d, "ue3.bad-model-component", "element light map did not parse")
			return
		}
		r.pos += 4 // Component
		r.pos += 4 // Material
		if !skip_words(&r) {
			diag.err(&d, "ue3.bad-model-component", "element nodes did not parse")
			return
		}
		if !skip_refs(&r) {
			diag.err(&d, "ue3.bad-model-component", "element shadow maps did not parse")
			return
		}
		guids := read_i32(&r)
		if r.failed || guids < 0 || guids > 1_000_000 || i64(guids) * 16 > i64(r.limit - r.pos) {
			diag.err(&d, "ue3.bad-model-component", "element irrelevant lights did not parse")
			return
		}
		r.pos += int(guids) * 16
	}
	result.elements = int(elements)
	r.pos += 2 // ComponentIndex
	if !skip_words(&r) {
		diag.err(&d, "ue3.bad-model-component", "component nodes did not parse")
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.model-component-layout", fmt.aprintf("UModelComponent consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
