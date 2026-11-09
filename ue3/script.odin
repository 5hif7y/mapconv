package ue3

import "core:fmt"
import "base:runtime"
import "../diag"

// UStruct::Serialize (Core/Src/UnClass.cpp:1195) and UFunction::Serialize
// (UnClass.cpp:3031) for package version 576 (< VER_MOVED_SUPERFIELD_TO_USTRUCT
// 756, < VER_USTRUCT_SERIALIZE_ONDISK_SCRIPTSIZE 639).
//
//	SuperField            INT   (written by UField for versions before 756)
//	Next                  INT
//	ScriptText            FString
//	Children              INT
//	CppText               FString
//	Line, TextPos         INT
//	ScriptBytecodeSize    INT
//	bytecode              ScriptBytecodeSize bytes (see below)
//
// Below 639 the on-disk bytecode is inline and `ScriptBytecodeSize` is also the
// on-disk length, so the stream can be skipped; the last byte must be
// EX_EndOfScript (0x53), which is the check that keeps this from being a blind
// skip. From 639 the file carries a separate storage size and the stream must be
// decoded expression by expression, so the reader refuses those packages.
//
// UFunction then writes iNative (WORD), OperPrecedence (BYTE), FunctionFlags
// (DWORD), RepOffset (WORD, only when FUNC_Net is set) and FriendlyName, which
// is an FName (UnClass.h:388), so eight bytes and not a string.
Script_Kind :: enum {
	Plain,
	Script_Struct,
	Function,
	State_Obj,
}

Script_Body :: struct {
	children:  int,
	bytecode:  int,
	flags:     u32,
	has_remap: bool,
}

read_script_struct :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Script_Body, d: diag.Diagnostics) {
	return read_script(pkg, export_index, .Plain, allocator)
}

// UState::Serialize (UnClass.cpp:1876) adds, after the UStruct body, the two
// legacy probe masks (version < 691), LabelTableOffset, StateFlags and the
// function map (an FName to UFunction reference map, twelve bytes per pair).
read_state :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Script_Body, d: diag.Diagnostics) {
	return read_script(pkg, export_index, .State_Obj, allocator)
}

// UScriptStruct::Serialize (UnClass.cpp:1763) appends StructFlags and then the
// tagged defaults, so the tag stream belongs to the same payload.
read_script_struct_with_defaults :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Script_Body, d: diag.Diagnostics) {
	return read_script(pkg, export_index, .Script_Struct, allocator)
}

read_function :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Script_Body, d: diag.Diagnostics) {
	return read_script(pkg, export_index, .Function, allocator)
}

read_script :: proc(
	pkg: ^Package,
	export_index: int,
	kind: Script_Kind,
	allocator: runtime.Allocator,
) -> (result: Script_Body, d: diag.Diagnostics) {
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
	if version >= 639 {
		diag.err(&d, "ue3.script-version", "packages from 639 on carry a separate bytecode storage size")
		return
	}
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	_ = read_i32(&r) // SuperField
	_ = read_i32(&r) // Next
	_ = read_fstring(&r) // ScriptText
	result.children = int(read_i32(&r))
	_ = read_fstring(&r) // CppText
	_ = read_i32(&r) // Line
	_ = read_i32(&r) // TextPos
	bytecode := read_i32(&r)
	if r.failed || bytecode < 0 || i64(bytecode) > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-script", fmt.aprintf("implausible bytecode size %d", bytecode))
		return
	}
	if bytecode > 0 {
		if int(pkg.data[r.pos + int(bytecode) - 1]) != 0x53 {
			diag.err(&d, "ue3.bad-script", "the script does not end with EX_EndOfScript")
			return
		}
	}
	r.pos += int(bytecode)
	result.bytecode = int(bytecode)
	if kind == .State_Obj {
		if version < 691 {
			_ = read_u64(&r) // legacy ProbeMask
			_ = read_u64(&r) // legacy IgnoreMask
		} else {
			_ = read_u32(&r) // ProbeMask
		}
		_ = read_u16(&r) // LabelTableOffset
		_ = read_u32(&r) // StateFlags
		functions := read_i32(&r)
		if r.failed || functions < 0 || i64(functions) * 12 > i64(r.limit - r.pos) {
			diag.err(&d, "ue3.bad-state", fmt.aprintf("implausible state function count %d", functions))
			return
		}
		for _ in 0 ..< int(functions) {
			name_index := read_i32(&r)
			_ = read_i32(&r)
			_ = read_i32(&r)
			if r.failed || name_index < -1 || int(name_index) > len(pkg.names) {
				diag.err(&d, "ue3.bad-state", "state function map entry is out of range")
				return
			}
		}
		if r.pos != head.end_offset {
			diag.err(&d, "ue3.state-layout", fmt.aprintf("UState consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
			return
		}
		return
	}
	if kind == .Script_Struct {
		result.flags = read_u32(&r)
		tags := read_tag_stream(pkg, &r, head.end_offset, int(e.serial_size), allocator, &d)
		delete(tags)
		if diag.has_errors(&d) {
			return
		}
		if r.pos != head.end_offset {
			diag.err(&d, "ue3.script-layout", fmt.aprintf("UScriptStruct consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
			return
		}
		return
	}
	if kind == .Plain {
		if r.pos != head.end_offset {
			diag.err(&d, "ue3.script-layout", fmt.aprintf("UStruct consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
			return
		}
		return
	}
	_ = read_u16(&r) // iNative
	_ = read_u8(&r) // OperPrecedence
	flags := read_u32(&r)
	if r.failed {
		diag.err(&d, "ue3.bad-script", "function flags ran past the export")
		return
	}
	result.flags = flags
	if flags & 0x40 != 0 { // FUNC_Net
		_ = read_u16(&r) // RepOffset
	}
	// FriendlyName is an FName (UnClass.h:388), not a string: index and number.
	name_index := read_i32(&r)
	_ = read_i32(&r)
	if name_index < -1 || int(name_index) > len(pkg.names) {
		diag.err(&d, "ue3.bad-script", fmt.aprintf("friendly name index %d out of range", name_index))
		return
	}
	if r.failed {
		diag.err(&d, "ue3.bad-script", "the function trailer ran past the export")
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.script-layout", fmt.aprintf("UFunction consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
