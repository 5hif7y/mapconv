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
	if !need(&r, int(level.game_sequences_count) * 4) {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	r.pos += int(level.game_sequences_count) * 4

	// The rest of ULevel::Serialize for package version 576 follows the source
	// in Engine/Src/UnLevel.cpp. Every array is bounded by the export end, so a
	// wrong layout cannot silently consume another export.
	skip_bulk :: proc(r: ^Reader) -> bool {
		element_size := read_i32(r)
		count := read_i32(r)
		if r.failed || element_size <= 0 || element_size > 256 || count < 0 || count > 50_000_000 {
			return false
		}
		if i64(element_size) * i64(count) > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(element_size) * int(count)
		return true
	}
	skip_map_of_arrays :: proc(r: ^Reader, stride: int) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 1_000_000 {
			return false
		}
		for _ in 0 ..< int(count) {
			_ = read_i32(r) // key
			n := read_i32(r)
			if r.failed || n < 0 || n > 1_000_000 {
				return false
			}
			if i64(n) * i64(stride) > i64(r.limit - r.pos) {
				return false
			}
			r.pos += int(n) * stride
		}
		return true
	}
	skip_pairs :: proc(r: ^Reader, value_size: int) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 1_000_000 {
			return false
		}
		if i64(count) * i64(4 + value_size) > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(count) * (4 + value_size)
		return true
	}
	// TextureToInstancesMap: TMap<UTexture2D*, TArray<FStreamableTextureInstance>>
	// (FStreamableTextureInstance = FSphere 16 + FLOAT 4).
	if !skip_map_of_arrays(&r, 20) {
		diag.err(&d, "ue3.bad-level", "TextureToInstancesMap did not parse")
		return
	}
	// CachedPhysBSPData.BulkSerialize
	if !skip_bulk(&r) {
		diag.err(&d, "ue3.bad-level", "CachedPhysBSPData did not parse")
		return
	}
	// CachedPhysSMDataMap: TMultiMap<UStaticMesh*, FCachedPhysSMData> (16 B).
	if !skip_pairs(&r, 16) {
		diag.err(&d, "ue3.bad-level", "CachedPhysSMDataMap did not parse")
		return
	}
	// CachedPhysSMDataStore: TArray<FKCachedConvexData>, one array of bulks each.
	store_count := read_i32(&r)
	if r.failed || store_count < 0 || store_count > 1_000_000 {
		diag.err(&d, "ue3.bad-level", "CachedPhysSMDataStore did not parse")
		return
	}
	for _ in 0 ..< int(store_count) {
		elements := read_i32(&r)
		if r.failed || elements < 0 || elements > 1_000_000 {
			diag.err(&d, "ue3.bad-level", "CachedPhysSMDataStore element did not parse")
			return
		}
		for _ in 0 ..< int(elements) {
			if !skip_bulk(&r) {
				diag.err(&d, "ue3.bad-level", "CachedPhysSMDataStore payload did not parse")
				return
			}
		}
	}
	// CachedPhysPerTriSMDataMap (20 B per value) and its bulk store.
	if !skip_pairs(&r, 20) {
		diag.err(&d, "ue3.bad-level", "CachedPhysPerTriSMDataMap did not parse")
		return
	}
	per_tri_count := read_i32(&r)
	if r.failed || per_tri_count < 0 || per_tri_count > 1_000_000 {
		diag.err(&d, "ue3.bad-level", "CachedPhysPerTriSMDataStore did not parse")
		return
	}
	for _ in 0 ..< int(per_tri_count) {
		if !skip_bulk(&r) {
			diag.err(&d, "ue3.bad-level", "CachedPhysPerTriSMDataStore payload did not parse")
			return
		}
	}
	_ = read_i32(&r) // CachedPhysBSPDataVersion
	_ = read_i32(&r) // CachedPhysSMDataVersion
	// ForceStreamTextures: TMap<UTexture2D*, UBOOL>.
	if !skip_pairs(&r, 4) {
		diag.err(&d, "ue3.bad-level", "ForceStreamTextures did not parse")
		return
	}
	_ = read_i32(&r) // NavListStart
	_ = read_i32(&r) // NavListEnd
	_ = read_i32(&r) // CoverListStart
	_ = read_i32(&r) // CoverListEnd
	cross := read_i32(&r)
	if r.failed || cross < 0 || cross > 1_000_000 {
		diag.err(&d, "ue3.bad-level", "CrossLevelActors did not parse")
		return
	}
	if i64(cross) * 4 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-level", "CrossLevelActors overruns the export")
		return
	}
	r.pos += int(cross) * 4
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.level-layout", fmt.aprintf("ULevel consumed %d of %d bytes", r.pos - head.body_offset, int(e.serial_size) - (head.body_offset - int(e.serial_offset))))
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
