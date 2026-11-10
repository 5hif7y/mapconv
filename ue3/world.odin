// UWorld: the world object that every map package carries.
//
// UWorld::Serialize (Engine/Src/UnWorld.cpp:88) writes, after the shared object
// prelude:
//
//	PersistentLevel                       object reference
//	PersistentFaceFXAnimSet               from VER_WORLD_PERSISTENT_FACEXANIMSET (575)
//	EditorViews[0..3]                     four FLevelViewportInfo, 28 bytes each
//	                                      (FVector, FRotator, ortho zoom)
//	SaveGameSummary_DEPRECATED            object reference
//	DecalManager                          below VER_REMOVED_DECAL_MANAGER_FROM_UWORLD (496)
//	ExtraReferencedObjects                count and references
//
// The arrays annotated "not loading and not saving" in the source (Levels,
// CurrentLevel, the net drivers, the pools) are editor state and are not written
// to a cooked package. Every reference is checked against the package tables, so
// the reader cannot pass by consuming a size.
package ue3

import "core:fmt"
import "core:math"
import "../diag"

VER_WORLD_PERSISTENT_FACEXANIMSET :: 575
VER_REMOVED_DECAL_MANAGER_FROM_UWORLD :: 496

// Level_View mirrors FLevelViewportInfo (Engine/Inc/UnLevel.h:321): a camera
// position, a rotator and the orthographic zoom.
Level_View :: struct {
	cam_position: [3]f32,
	cam_rotation: [3]i32,
	ortho_zoom:   f32,
}

World :: struct {
	export_index:      int,
	persistent_level:  i32,
	persistent_facefx: i32,
	editor_views:      [4]Level_View,
	save_game_summary: i32,
	decal_manager:     i32,
	extra_referenced:  []i32,
}

read_world :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (world: World, d: diag.Diagnostics) {
	d = diag.init()
	world.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller.
		d = head_d
		return
	}
	defer delete(head_d.items)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	version := engine_version(&pkg.summary)

	world.persistent_level = read_i32(&r)
	if !valid_object_reference(pkg, world.persistent_level) {
		diag.err(&d, "ue3.bad-world", fmt.aprintf("persistent level reference %d out of range", world.persistent_level))
		return
	}
	if version >= VER_WORLD_PERSISTENT_FACEXANIMSET {
		world.persistent_facefx = read_i32(&r)
		if !valid_object_reference(pkg, world.persistent_facefx) {
			diag.err(&d, "ue3.bad-world", fmt.aprintf("face fx reference %d out of range", world.persistent_facefx))
			return
		}
	}
	for i in 0 ..< 4 {
		view := &world.editor_views[i]
		for k in 0 ..< 3 {
			value := read_f32(&r)
			if !(value == value) || math.abs(value) > 1e12 {
				diag.err(&d, "ue3.bad-world", fmt.aprintf("editor view %d holds a non-finite position", i))
				return
			}
			view.cam_position[k] = value
		}
		for k in 0 ..< 3 {
			// A rotator component is a raw angle word; the layout is verified by
			// the body length and the references, so the value is kept as read
			// instead of being filtered (some cooked maps store editor state that
			// is not a proper rotation).
			view.cam_rotation[k] = read_i32(&r)
		}
		view.ortho_zoom = read_f32(&r)
		if !(view.ortho_zoom == view.ortho_zoom) || math.abs(view.ortho_zoom) > 1e12 {
			diag.err(&d, "ue3.bad-world", fmt.aprintf("editor view %d holds a non-finite zoom", i))
			return
		}
	}
	world.save_game_summary = read_i32(&r)
	if !valid_object_reference(pkg, world.save_game_summary) {
		diag.err(&d, "ue3.bad-world", fmt.aprintf("save game summary reference %d out of range", world.save_game_summary))
		return
	}
	if version < VER_REMOVED_DECAL_MANAGER_FROM_UWORLD {
		world.decal_manager = read_i32(&r)
		if !valid_object_reference(pkg, world.decal_manager) {
			diag.err(&d, "ue3.bad-world", fmt.aprintf("decal manager reference %d out of range", world.decal_manager))
			return
		}
	}
	count := read_i32(&r)
	if r.failed || count < 0 || count > 1_000_000 {
		diag.err(&d, "ue3.bad-world", fmt.aprintf("implausible extra reference count %d", count))
		return
	}
	world.extra_referenced = make([]i32, int(count), allocator)
	for i in 0 ..< int(count) {
		reference := read_i32(&r)
		if r.failed || !valid_object_reference(pkg, reference) {
			diag.err(&d, "ue3.bad-world", fmt.aprintf("extra reference %d out of range", reference))
			return
		}
		world.extra_referenced[i] = reference
	}
	if r.failed {
		diag.err(&d, "ue3.bad-world", "the world body ran past the export")
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.bad-world", fmt.aprintf("world consumed %d of %d body bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
