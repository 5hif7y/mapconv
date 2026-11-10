// UClass payloads. A class export carries no tagged properties of its own: its
// body is the class record itself, which is what makes it different from every
// other object in the package. The layout below follows
// UClass::Serialize (Core/Src/UnClass.cpp:2589) through UState::Serialize
// (:1876), UStruct::Serialize (:1195), UField::Serialize (:84) and
// UObject::Serialize (Core/Src/UnObj.cpp:1654), with the branch selection of
// package version 576 that the CrimeCraft packages use.
//
// Three details decide the byte count and are easy to get wrong:
//
//   * UObject::Serialize writes the net index first. In a cooked package the
//     loader sets the net index from the linker index, so the field normally
//     repeats the export it belongs to, but that is a consequence and not a rule.
//   * UState::Serialize writes LabelTableOffset as a WORD, not a dword. That is
//     why class payloads are four-byte aligned everywhere except a remainder of
//     two, and a reader with a dword there is off by two bytes from that point on.
//   * FImplementedInterface is eight bytes in this build: the class reference and
//     the pointer offset. The editor-only flag is not serialized.
package ue3

import "core:fmt"
import "../diag"

// VER_REDUCED_PROBEMASK_REMOVED_IGNOREMASK (Core/Inc/UnObjVer.h:355). Below it
// UState writes both masks, a sixteen byte block; above it only one.
VER_REDUCED_PROBEMASK_REMOVED_IGNOREMASK :: 691

// VER_SCRIPT_BIND_DLL_FUNCTIONS (:296). Below it UClass writes no DLL bind name.
VER_SCRIPT_BIND_DLL_FUNCTIONS :: 655

Class_Body :: struct {
	net_index:      i32,
	super_field:    i32,
	children:       i32,
	bytecode_size:  i32,
	probe_mask:     u64,
	ignore_mask:    u64,
	label_offset:   u16,
	state_flags:    u32,
	function_count: int,
	class_flags:    u32,
	class_within:   i32,
	default_object: i32,
	end_offset:     int,
}

// read_class_body decodes a class export and requires the cursor to land exactly
// on the end of the payload. The super class reference is checked against the
// export table, which no garbage can satisfy by accident.
read_class_body :: proc(
	pkg: ^Package,
	export_index: int,
) -> (result: Class_Body, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	if e.serial_size <= 0 || e.serial_offset < 0 || int(e.serial_offset) + int(e.serial_size) > len(pkg.data) {
		diag.err(&d, "ue3.export-out-of-range", "the class payload lies outside the file")
		return
	}
	end := int(e.serial_offset) + int(e.serial_size)
	version := engine_version(&pkg.summary)
	r := Reader{data = pkg.data, pos = int(e.serial_offset), limit = end}

	// UObject::Serialize: the net index, and then nothing, because a class has no
	// properties of its own to serialize at this point.
	result.net_index = read_i32(&r)

	// UField::Serialize: for versions below 756 the super field is written here.
	// UStruct does not write SuperStruct again, so this is the only copy.
	result.super_field = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if result.super_field != e.super_index {
		diag.err(
			&d,
			"ue3.bad-class-super",
			fmt.aprintf("the body names super %d but the export table says %d", result.super_field, e.super_index),
		)
		return
	}

	_ = read_i32(&r) // Next
	_ = read_fstring(&r) // ScriptText
	result.children = read_i32(&r)
	_ = read_fstring(&r) // CppText
	_ = read_i32(&r) // Line
	_ = read_i32(&r) // TextPos
	result.bytecode_size = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if result.bytecode_size < 0 || i64(result.bytecode_size) > i64(end - r.pos) {
		diag.err(&d, "ue3.bad-class-bytecode", fmt.aprintf("implausible bytecode size %d", result.bytecode_size))
		return
	}
	if result.bytecode_size > 0 && pkg.data[r.pos + int(result.bytecode_size) - 1] != 0x53 {
		diag.err(&d, "ue3.bad-class-bytecode", "the class script does not end with EX_EndOfScript")
		return
	}
	r.pos += int(result.bytecode_size)

	// UState::Serialize.
	if version < VER_REDUCED_PROBEMASK_REMOVED_IGNOREMASK {
		result.probe_mask = read_u64(&r)
		result.ignore_mask = read_u64(&r)
	} else {
		result.probe_mask = read_u64(&r)
	}
	result.label_offset = read_u16(&r)
	result.state_flags = read_u32(&r)
	result.function_count = int(read_i32(&r))
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if result.function_count < 0 || i64(result.function_count) * 12 > i64(end - r.pos) {
		diag.err(&d, "ue3.bad-class-functions", fmt.aprintf("the function map declares %d entries", result.function_count))
		return
	}
	r.pos += result.function_count * 12

	// UClass::Serialize.
	result.class_flags = read_u32(&r)
	result.class_within = read_i32(&r)
	_ = read_name_ref(&r) // ClassConfigName
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if !skip_counted(&r, end, 12, "component map") {
		diag.err(&d, "ue3.bad-class-map", r.message)
		return
	}
	if !skip_counted(&r, end, 8, "interfaces") {
		diag.err(&d, "ue3.bad-class-interfaces", r.message)
		return
	}
	// HideCategories, AutoExpandCategories and AutoCollapseCategories are written
	// as three arrays of names even in a cooked package of this build.
	for _ in 0 ..< 3 {
		if !skip_counted(&r, end, 8, "categories") {
			diag.err(&d, "ue3.bad-class-categories", r.message)
			return
		}
	}
	if version >= VER_SCRIPT_BIND_DLL_FUNCTIONS {
		_ = read_name_ref(&r) // DLLBindName
	}
	result.default_object = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if r.pos != end {
		diag.err(
			&d,
			"ue3.class-end-mismatch",
			fmt.aprintf("the class body ends at %d but the export ends at %d", r.pos, end),
		)
		return
	}
	result.end_offset = r.pos
	return
}

// skip_counted reads a count and strides over that many records, refusing counts
// that cannot fit in what is left of the payload.
skip_counted :: proc(r: ^Reader, end, stride: int, what: string) -> bool {
	count := int(read_i32(r))
	if r.failed {
		return false
	}
	if count < 0 || i64(count) * i64(stride) > i64(end - r.pos) {
		reader_fail(r, fmt.aprintf("the %s declares %d entries", what, count))
		return false
	}
	r.pos += count * stride
	return true
}
