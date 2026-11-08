// ULevel: the level object and its actor list.
//
// ULevelBase::Serialize writes, after the shared object prelude:
//
//	TTransArray<AActor*> Actors;   // owner reference, count, package indices
//	FURL                 URL;      // 5 FStrings, port, valid
//
// and ULevel::Serialize continues with the model reference, the model component
// array (a plain TArray, no owner) and the game sequences (also a plain array). This stage exposes the
// actor list and those references; each actor's own payload (properties such
// as Location, Rotation, StaticMesh) is a separate, still open, stage.
package ue3

import "core:fmt"
import "../diag"

// Url mirrors FURL: five strings plus the port and validity flag. The map name
// is the useful one (it names the level package).
Url :: struct {
	protocol: string,
	host:     string,
	map_name: string,
	portal:   string,
	options:  string,
	port:     i32,
	valid:    bool,
}

// Level is a parsed ULevel: the actor references and the model/components
// references that the native body stores before the editor-only arrays.
Level :: struct {
	export_index:          int,
	actors_owner:          i32,
	actors:                []i32,
	url:                  Url,
	model_index:          i32,
	model_components:     []i32,
	game_sequences_count: i32,
}

read_level :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (level: Level, d: diag.Diagnostics) {
	d = diag.init()
	level.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
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

	// Actors: TTransArray -> owner reference, then count and package indices.
	level.actors_owner = read_i32(&r)
	actor_count := read_i32(&r)
	if r.failed || actor_count < 0 || actor_count > 1_000_000 {
		diag.err(&d, "ue3.bad-level", fmt.aprintf("implausible actor count %d", actor_count))
		return
	}
	level.actors = make([]i32, int(actor_count), allocator)
	for i in 0..<int(actor_count) {
		level.actors[i] = read_i32(&r)
	}

	level.url = Url {
		protocol = read_fstring(&r),
		host     = read_fstring(&r),
		map_name = read_fstring(&r),
		portal   = read_fstring(&r),
		options  = read_fstring(&r),
		port     = read_i32(&r),
		valid    = read_i32(&r) != 0,
	}
	level.model_index = read_i32(&r)

	component_count := read_i32(&r)
	if r.failed || component_count < 0 || component_count > 1_000_000 {
		diag.err(&d, "ue3.bad-level", fmt.aprintf("implausible model component count %d", component_count))
		return
	}
	level.model_components = make([]i32, int(component_count), allocator)
	for i in 0..<int(component_count) {
		level.model_components[i] = read_i32(&r)
	}

	level.game_sequences_count = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if level.game_sequences_count < 0 || level.game_sequences_count > 1_000_000 {
		diag.err(&d, "ue3.bad-level", fmt.aprintf("implausible sequence count %d", level.game_sequences_count))
		return
	}
	// The sequences follow; their payloads are out of scope here.
	if !need(&r, int(level.game_sequences_count) * 4) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	return
}

// actor_class_name resolves one of the level's actor references to its class.
actor_class_name :: proc(pkg: ^Package, actor_index: i32) -> string {
	if package_index_kind(actor_index) != .Export {
		return ""
	}
	index := int(actor_index) - 1
	if index < 0 || index >= len(pkg.exports) {
		return ""
	}
	return export_class_name(pkg, pkg.exports[index])
}
