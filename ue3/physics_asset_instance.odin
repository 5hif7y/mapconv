package ue3

import "core:fmt"
import "../diag"

// UPhysicsAssetInstance::Serialize (Engine/Src/UnPhysAsset.cpp:1923) writes
// only CollisionDisableTable, a TMap<FRigidBodyIndexPair, UBOOL>: the key is
// two INTs and the value one UBOOL, so twelve bytes per entry.
Physics_Asset_Instance :: struct {
	entries: int,
}

read_physics_asset_instance :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Physics_Asset_Instance, d: diag.Diagnostics) {
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
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	count := read_i32(&r)
	if r.failed || count < 0 || count > 100_000 || i64(count) * 12 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-physics-asset", "collision disable table did not parse")
		return
	}
	r.pos += int(count) * 12
	result.entries = int(count)
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.physics-asset-layout", fmt.aprintf("UPhysicsAssetInstance consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
