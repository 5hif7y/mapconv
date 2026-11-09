package ue3

import "core:fmt"
import "../diag"

// UProperty::Serialize (Core/Src/UnProp.cpp:145) with the measured layout of
// build 4701. The tree's source writes a DWORD of flags, but the corpus only
// reconciles with a 64 bit flags word: the high half carries real bits
// (0x2, 0x8, 0x10000000) in 278 properties and, with a DWORD, the category name
// would land on an impossible FName (index 0, number 35843). Measured layout:
//
//	SuperField       INT
//	Next             INT
//	ArrayDim         INT
//	PropertyFlags    QWORD
//	Category         FName (index, number)
//	ArraySizeEnum    INT (an export reference)
//	RepOffset        WORD, only when CPF_Net (0x20) is set
//	class payload    one reference (Object, Struct, Array, Byte, Component,
//	                 Interface) or two (Delegate, Map)
//
// The totals match the class families exactly: 32 bytes plus two when the
// property is a network property, plus four or eight for the class reference.
CPF_NET :: 0x20

Property_Body :: struct {
	array_dim: int,
	flags:     u64,
	category:  i32,
}

read_property :: proc(
	pkg: ^Package,
	export_index: int,
	class_name: string,
	allocator := context.allocator,
) -> (result: Property_Body, d: diag.Diagnostics) {
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
	array_dim := read_i32(&r)
	flags := read_u64(&r)
	category := read_i32(&r)
	_ = read_i32(&r) // FName number
	enum_ref := read_i32(&r)
	if r.failed || array_dim < 0 || array_dim > 65_536 {
		diag.err(&d, "ue3.bad-property", "the property header did not parse")
		return
	}
	if category < -1 || int(category) > len(pkg.names) {
		diag.err(&d, "ue3.bad-property", fmt.aprintf("category name index %d out of range", category))
		return
	}
	if !valid_object_reference(pkg, enum_ref) {
		diag.err(&d, "ue3.bad-property", fmt.aprintf("array size enum reference %d out of range", enum_ref))
		return
	}
	if flags & CPF_NET != 0 {
		_ = read_u16(&r) // RepOffset
	}
	references := 0
	switch class_name {
	case "ObjectProperty", "StructProperty", "ArrayProperty", "ByteProperty", "ComponentProperty", "InterfaceProperty":
		references = 1
	case "DelegateProperty", "MapProperty", "ClassProperty":
		references = 2
	}
	for _ in 0 ..< references {
		reference := read_i32(&r)
		if r.failed || !valid_object_reference(pkg, reference) {
			diag.err(&d, "ue3.bad-property", fmt.aprintf("%s class reference %d out of range", class_name, reference))
			return
		}
	}
	result = Property_Body {
		array_dim = int(array_dim),
		flags     = flags,
		category  = category,
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.property-layout", fmt.aprintf("%s consumed %d of %d bytes", class_name, r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}

// valid_object_reference checks a serialized UObject pointer: non-negative values
// index the export table, negative values index the import table as -1 - index.
valid_object_reference :: proc(pkg: ^Package, value: i32) -> bool {
	if value >= 0 {
		return int(value) < len(pkg.exports)
	}
	index := int(-value) - 1
	return index >= 0 && index < len(pkg.imports)
}
