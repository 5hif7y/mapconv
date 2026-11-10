// UGuidCache stores the package GUIDs of the cooked content.
//
// UGuidCache::Serialize (Engine/Src/UnConn.cpp:83) is Super::Serialize followed by
// `Ar << PackageGuidMap`, a TMap<FName, FGuid>. A UE3 map is written as a count and
// then the key/value pairs, so the payload is a count followed by that many records
// of eight bytes of name and sixteen bytes of GUID.
//
// The check is arithmetic on two independent numbers: the count has to match the
// bytes that are left, and every name index has to exist in the name table.
package ue3

import "core:fmt"
import "../diag"

Guid_Cache :: struct {
	entries:    int,
	end_offset: int,
}

read_guid_cache :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Guid_Cache, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	head, head_d := read_object_head(pkg, pkg.exports[export_index], allocator, export_index)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	delete(head_d.items)
	end := head.end_offset
	r := Reader{data = pkg.data, pos = head.body_offset, limit = end}
	count := int(read_i32(&r))
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if count < 0 || i64(count) * 24 != i64(end - r.pos) {
		diag.err(
			&d,
			"ue3.bad-guid-cache",
			fmt.aprintf("a cache of %d packages cannot hold %d bytes", count, end - r.pos),
		)
		return
	}
	for _ in 0 ..< count {
		name := read_name_ref(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		if name.index < 0 || int(name.index) >= len(pkg.names) {
			diag.err(&d, "ue3.bad-guid-cache", fmt.aprintf("name %d is outside the name table", name.index))
			return
		}
		_ = read_guid(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
	}
	result.entries = count
	result.end_offset = r.pos
	return
}
