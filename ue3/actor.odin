// Actor properties: the transforms every map needs.
//
// With the state-frame prelude understood (see object.odin), an actor's tagged
// properties are finally reachable: Location is a Vector struct, Rotation a
// Rotator struct (three 32-bit angle units), DrawScale a float. Mesh references
// live in the actor's component, which is a second object.
package ue3

import "core:fmt"
import "../diag"

Actor_Info :: struct {
	export_index: int,
	class_name:   string,
	location:     [3]f32,
	rotation:     [3]i32, // Pitch, Yaw, Roll in UE3 rotator units
	draw_scale:   f32,
	has_location: bool,
	has_rotation: bool,
	has_draw_scale: bool,
	// StaticMeshComponent or another component reference, when present.
	component_index: i32,
	has_component:   bool,
	// Mesh asset name resolved through the component, when it has one.
	mesh_name:       string,
}

read_actor_info :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (info: Actor_Info, d: diag.Diagnostics) {
	d = diag.init()
	info.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	info.class_name = export_class_name(pkg, e)
	head, head_d := read_object_head(pkg, e, allocator)
	defer delete(head_d.items)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}

	if tag, ok := find_tag(pkg, head.tags, "Location"); ok {
		if value, ok2 := tag_vec3(pkg, tag); ok2 {
			info.location = value
			info.has_location = true
		}
	}
	if tag, ok := find_tag(pkg, head.tags, "Rotation"); ok {
		if value, ok2 := tag_rotator(pkg, tag); ok2 {
			info.rotation = value
			info.has_rotation = true
		}
	}
	if tag, ok := find_tag(pkg, head.tags, "DrawScale"); ok {
		if value, ok2 := tag_f32(pkg, tag); ok2 {
			info.draw_scale = value
			info.has_draw_scale = true
		}
	}
	for name in ([]string{"StaticMeshComponent", "BrushComponent", "LightComponent", "ParticleSystemComponent"}) {
		if tag, ok := find_tag(pkg, head.tags, name); ok {
			if value, ok2 := tag_i32(pkg, tag); ok2 && value != 0 {
				info.component_index = value
				info.has_component = true
				break
			}
		}
	}
	for name in ([]string{"StaticMesh", "SkeletalMesh", "ParticleSystem"}) {
		if !info.has_component {
			break
		}
		if package_index_kind(info.component_index) != .Export {
			break
		}
		component := int(info.component_index) - 1
		if component < 0 || component >= len(pkg.exports) {
			break
		}
		comp_head, comp_d := read_object_head(pkg, pkg.exports[component], allocator)
		defer delete(comp_d.items)
		if diag.has_errors(&comp_d) {
			break
		}
		if tag, ok := find_tag(pkg, comp_head.tags, name); ok {
			if value, ok2 := tag_i32(pkg, tag); ok2 && value != 0 {
				info.mesh_name = package_index_name(pkg, value)
			}
		}
		break
	}
	if !info.has_draw_scale {
		info.draw_scale = 1
	}
	return
}
