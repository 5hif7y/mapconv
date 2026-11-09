package ue3

import "core:fmt"
import "../diag"

// UConst::Serialize (Core/Src/UnClass.cpp:3159) is a UField plus the constant's
// text: SuperField, Next, then the value as an FString.
read_const :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (d: diag.Diagnostics) {
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
	_ = read_i32(&r) // SuperField
	_ = read_i32(&r) // Next
	_ = read_fstring(&r) // Value
	if r.failed {
		diag.err(&d, "ue3.bad-const", "the constant text ran past the export")
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.const-layout", fmt.aprintf("UConst consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
	}
	return
}

// UEnum::Serialize (Core/Src/UnCoreNative.cpp:438) writes the enum name table as
// a TArray<FName>: a count followed by eight bytes per entry.
read_enum :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (d: diag.Diagnostics) {
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
	_ = read_i32(&r) // SuperField
	_ = read_i32(&r) // Next
	count := read_i32(&r)
	if r.failed || count < 0 || i64(count) * 8 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-enum", fmt.aprintf("implausible enum name count %d", count))
		return
	}
	for _ in 0 ..< int(count) {
		index := read_i32(&r)
		_ = read_i32(&r)
		if r.failed || index < 0 || int(index) > len(pkg.names) {
			diag.err(&d, "ue3.bad-enum", "enum name index out of range")
			return
		}
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.enum-layout", fmt.aprintf("UEnum consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
	}
	return
}
