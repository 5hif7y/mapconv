// ULightComponent: the eight byte tail that every light component carries.
//
// ULightComponent::Serialize (Engine/Src/LightComponent.cpp:413) writes two
// unused convex volume arrays below VER_REMOVE_UNUSED_LIGHTING_PROPERTIES (829):
//
//	TArray<FConvexVolume> Dummy;   // count, then the records
//	TArray<FConvexVolume> Dummy2;
//
// The tree build is 576 and every light component in the corpus (point, spot,
// directional, sky, beast area) leaves exactly the two arrays after the tag
// stream. FConvexVolume (Engine/Inc/ConvexVolume.h:51) has no serializer of its
// own, so each record is its two plane arrays: a count and sixteen byte planes,
// twice per record.
package ue3

import "core:fmt"
import "../diag"

VER_REMOVE_UNUSED_LIGHTING_PROPERTIES :: 829

Light_Component :: struct {
	export_index: int,
	arrays:       int,
}

read_light_component_tail :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (light: Light_Component, d: diag.Diagnostics) {
	d = diag.init()
	light.export_index = export_index
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
	if engine_version(&pkg.summary) >= VER_REMOVE_UNUSED_LIGHTING_PROPERTIES {
		if r.pos != head.end_offset {
			diag.err(&d, "ue3.bad-light", fmt.aprintf("light component leaves %d bytes after the tag stream", head.end_offset - r.pos))
		}
		return
	}
	for i in 0 ..< 2 {
		volumes := read_i32(&r)
		if r.failed || volumes < 0 || volumes > 1024 {
			diag.err(&d, "ue3.bad-light", fmt.aprintf("unused convex volume array %d holds %d records", i, volumes))
			return
		}
		for _ in 0 ..< int(volumes) {
			for planes in 0 ..< 2 {
				count := read_i32(&r)
				if r.failed || count < 0 || count > 1024 {
					diag.err(&d, "ue3.bad-light", fmt.aprintf("convex volume plane array %d holds %d planes", planes, count))
					return
				}
				for _ in 0 ..< int(count) {
					for _ in 0 ..< 4 {
						value := read_f32(&r)
						if !(value == value) {
							diag.err(&d, "ue3.bad-light", "non-finite plane")
							return
						}
					}
				}
			}
		}
		light.arrays += 1
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.bad-light", fmt.aprintf("light component consumed %d of %d tail bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
