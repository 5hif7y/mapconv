// Object payloads: the prelude every export shares, and the UPolys brush
// polygons used by CrimeCraft maps.
//
// An export's serial data (SerialOffset, SerialSize) starts with a small object
// header:
//
//	INT32 NetIndex
//	FPropertyTag ...            zero or more, terminated by a tag named "None"
//	<native class data>
//
// The tag stream is only present for properties that differ from the class
// default; objects with no overrides carry just the terminator. Cooked packages
// store it uncompressed and untagged-binarily only when an archive asks for
// binary serialization, which the linker does not.
//
// Brush geometry is a UPolys object: an array of FPoly records. CrimeCraft keeps
// one UPolys per brush volume (BlockingVolume and friends), which makes the
// authoring geometry directly readable without evaluating CSG.
package ue3

import "core:fmt"
import "core:strings"
import "../diag"

// Property_Tag mirrors FPropertyTag (Core/Inc/UnPropertyTag.h) for version 576.
// StructProperty carries a struct name, BoolProperty a byte value (the tag has a
// 4-byte UBOOL before VER_PROPERTYTAG_BOOL_OPTIMIZATION), ByteProperty an enum
// name for VER_BYTEPROP_SERIALIZE_ENUM and later (not 576).
Property_Tag :: struct {
	name:         Name_Ref,
	type:         Name_Ref,
	size:         i32,
	array_index:  i32,
	struct_name:  Name_Ref,
	enum_name:    Name_Ref,
	bool_value:   u8,
	// File offset of the property value; the next tag starts at value_offset + size.
	value_offset: int,
}

// State_Frame mirrors the mutable part of FStateFrame (UnStack.h) as serialized
// by UObject::Serialize when the object has RF_HasStack. It comes *before* the
// NetIndex, which is why actor payloads start with data that is not a tag.
State_Frame :: struct {
	node:              i32,
	state_node:        i32,
	probe_mask:        u64,
	latent_action:     u16,
	state_stack_count: i32,
	offset:            i32,
}

RF_HAS_STACK :: 0x0200000000000000
RF_CLASS_DEFAULT_OBJECT :: 0x0000000000000200

// Object_Head is the shared prelude of an export payload.
Object_Head :: struct {
	// Present when the export has RF_HasStack (actors and script objects).
	state_frame:    State_Frame,
	has_state_frame: bool,
	// UComponent::PreSerialize writes the template owner class before everything
	// else; only components have it.
	template_owner_class: i32,
	has_template_owner:   bool,
	net_index:      i32,
	tags:           []Property_Tag,
	// Absolute file offset of the native class data (after the "None" tag).
	body_offset:    int,
	// Absolute end of this export's payload (SerialOffset + SerialSize).
	end_offset:     int,
}

// is_component_class reports whether an export is a UComponent, which writes a
// template reference before the object prelude. The class hierarchy lives in the
// imported script packages, so this uses the engine's naming convention.
is_component_class :: proc(pkg: ^Package, e: Export) -> bool {
	class := export_class_name(pkg, e)
	return strings.has_suffix(class, "Component")
}

is_none_name :: proc(pkg: ^Package, ref: Name_Ref) -> bool {
	return ref.index >= 0 && int(ref.index) < len(pkg.names) && ref.number == 0 && pkg.names[ref.index].text == "None"
}

// read_object_head reads the NetIndex and the tagged-property stream of an
// export. It bounds every read by the export's SerialSize.
read_object_head :: proc(
	pkg: ^Package,
	e: Export,
	allocator := context.allocator,
) -> (head: Object_Head, d: diag.Diagnostics) {
	d = diag.init()
	if e.serial_offset < 0 || e.serial_size < 0 || int(e.serial_offset) + int(e.serial_size) > len(pkg.data) {
		diag.err(
			&d,
			"ue3.export-out-of-range",
			fmt.aprintf("export payload @%d+%d lies outside the file", e.serial_offset, e.serial_size),
		)
		return
	}
	head.end_offset = int(e.serial_offset) + int(e.serial_size)
	r := Reader{data = pkg.data, pos = int(e.serial_offset), limit = head.end_offset}
	version := engine_version(&pkg.summary)

	// Execution stack: UObject::Serialize writes it before the NetIndex when the
	// object has RF_HasStack (every actor does).
	if e.object_flags & RF_HAS_STACK != 0 {
		sf: State_Frame
		sf.node = read_i32(&r)
		sf.state_node = read_i32(&r)
		sf.probe_mask = read_u64(&r)
		if version < VER_REDUCED_STATEFRAME_LATENTACTION_SIZE {
			sf.latent_action = u16(read_i32(&r))
		} else {
			sf.latent_action = read_u16(&r)
		}
		sf.state_stack_count = read_i32(&r)
		if r.failed || sf.state_stack_count < 0 || sf.state_stack_count > 10_000 {
			diag.err(&d, "ue3.bad-state-frame", fmt.aprintf("implausible state stack count %d", sf.state_stack_count))
			return
		}
		// FPushedState: State (4) + Node (4) + Offset (4).
		if !need(&r, int(sf.state_stack_count) * 12) {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		r.pos += int(sf.state_stack_count) * 12
		if sf.node != 0 {
			sf.offset = read_i32(&r)
		}
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		head.state_frame = sf
		head.has_state_frame = true
	}

	// Components serialize their template owner class before the object prelude.
	if is_component_class(pkg, e) {
		head.template_owner_class = read_i32(&r)
		head.has_template_owner = true
		if e.object_flags & RF_CLASS_DEFAULT_OBJECT != 0 {
			_ = read_name_ref(&r) // TemplateName
		}
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
	}

	head.net_index = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}

	tags := make([dynamic]Property_Tag, 0, 4, allocator)
	for {
		if r.pos + 8 > head.end_offset {
			diag.err(
				&d,
				"ue3.tags-overrun",
				fmt.aprintf("property tag stream overruns the export at offset %d", r.pos),
			)
			return
		}
		name := read_name_ref(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		if is_none_name(pkg, name) {
			break
		}
		type := read_name_ref(&r)
		size := read_i32(&r)
		array_index := read_i32(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		tag := Property_Tag {
			name         = name,
			type         = type,
			size         = size,
			array_index  = array_index,
		}
		type_text := name_text(pkg, type)
		if type_text == "StructProperty" {
			tag.struct_name = read_name_ref(&r)
		} else if type_text == "BoolProperty" {
			if version < VER_PROPERTYTAG_BOOL_OPTIMIZATION {
				tag.bool_value = u8(read_u32(&r))
			} else {
				tag.bool_value = read_u8(&r)
			}
		} else if type_text == "ByteProperty" && version >= VER_BYTEPROP_SERIALIZE_ENUM {
			tag.enum_name = read_name_ref(&r)
		}
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		if size < 0 || size > e.serial_size {
			diag.err(
				&d,
				"ue3.bad-property-size",
				fmt.aprintf("property %s declares size %d in a %d-byte export", name_text(pkg, name), size, e.serial_size),
			)
			return
		}
		tag.value_offset = r.pos
		if !need(&r, int(size)) {
			diag.err(
				&d,
				"ue3.tags-overrun",
				fmt.aprintf("property %s value overruns the export", name_text(pkg, name)),
			)
			return
		}
		r.pos += int(size)
		append(&tags, tag)
		if r.pos > head.end_offset {
			diag.err(&d, "ue3.tags-overrun", "property tag stream overruns the export")
			return
		}
	}
	if r.pos > head.end_offset {
		diag.err(&d, "ue3.tags-overrun", "property tag terminator overruns the export")
		return
	}
	head.tags = tags[:]
	head.body_offset = r.pos
	return
}

// ---------------------------------------------------------------------------
// UPolys
// ---------------------------------------------------------------------------

// Vec3 is the on-disk FVector: three little-endian floats.
Vec3 :: struct {
	x, y, z: f32,
}

// Poly is one FPoly (Engine/Inc/UnObj.h) as serialized by
// operator<<(FArchive&, FPoly&) for version 576. Rule-set pointers and lightmass
// settings are absent before versions 606 and 600 respectively and are not read.
Poly :: struct {
	base:              Vec3,
	normal:            Vec3,
	texture_u:         Vec3,
	texture_v:         Vec3,
	vertices:          []Vec3,
	poly_flags:        u32,
	actor_index:       i32, // FPackageIndex; 0 = none
	item_name:         Name_Ref,
	material_index:    i32, // FPackageIndex; 0 = none
	i_link:            i32,
	i_brush_poly:      i32,
	shadow_map_scale:  f32,
	lighting_channels: u32,
}

// Polys is a parsed UPolys object: the convex polygons of one brush.
Polys :: struct {
	export_index: int,
	owner_index:  i32,
	max_elements: i32,
	polygons:     []Poly,
	vertices:     int,
}

// read_polys parses the UPolys object of an export. The native body follows the
// shared object header:
//
//	INT32 Num, INT32 Max, FPackageIndex Owner, then Num × FPoly
read_polys :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Polys, d: diag.Diagnostics) {
	d = diag.init()
	result.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	defer delete(head_d.items)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	num := read_i32(&r)
	mx := read_i32(&r)
	owner := read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if num < 0 || num > 100_000 || mx < num {
		diag.err(&d, "ue3.bad-polys", fmt.aprintf("implausible UPolys header: num=%d max=%d", num, mx))
		return
	}
	result.owner_index = owner
	result.max_elements = mx
	result.polygons = make([]Poly, int(num), allocator)
	for i in 0..<int(num) {
		p: Poly
		p.base = read_vec3(&r)
		p.normal = read_vec3(&r)
		p.texture_u = read_vec3(&r)
		p.texture_v = read_vec3(&r)
		count := read_i32(&r)
		if count < 3 || count > 1024 {
			diag.err(&d, "ue3.bad-poly", fmt.aprintf("polygon %d has %d vertices", i, count))
			return
		}
		p.vertices = make([]Vec3, int(count), allocator)
		for v in 0..<int(count) {
			p.vertices[v] = read_vec3(&r)
		}
		p.poly_flags = read_u32(&r)
		p.actor_index = read_i32(&r)
		p.item_name = read_name_ref(&r)
		p.material_index = read_i32(&r)
		p.i_link = read_i32(&r)
		p.i_brush_poly = read_i32(&r)
		p.shadow_map_scale = read_f32(&r)
		p.lighting_channels = read_u32(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		result.vertices += int(count)
		result.polygons[i] = p
	}
	if r.pos != head.end_offset {
		diag.warn(
			&d,
			"ue3.polys-size-mismatch",
			fmt.aprintf(
				"UPolys parsed %d of %d bytes (%+d); the FPoly layout may differ",
				r.pos - int(e.serial_offset),
				e.serial_size,
				r.pos - head.end_offset,
			),
		)
	}
	return
}

read_vec3 :: proc(r: ^Reader) -> Vec3 {
	return Vec3{read_f32(r), read_f32(r), read_f32(r)}
}

// ---------------------------------------------------------------------------
// Property values
// ---------------------------------------------------------------------------

// tag_name is the property name of a tag.
tag_name :: proc(pkg: ^Package, tag: Property_Tag) -> string {
	return name_text(pkg, tag.name)
}

// find_tag looks a property up by name. The tag list is small.
find_tag :: proc(pkg: ^Package, tags: []Property_Tag, name: string) -> (Property_Tag, bool) {
	for tag in tags {
		if tag_name(pkg, tag) == name {
			return tag, true
		}
	}
	return {}, false
}

tag_reader :: proc(pkg: ^Package, tag: Property_Tag) -> Reader {
	return Reader {
		data = pkg.data,
		pos = tag.value_offset,
		limit = tag.value_offset + int(tag.size),
	}
}

tag_vec3 :: proc(pkg: ^Package, tag: Property_Tag) -> ([3]f32, bool) {
	if tag.size < 12 {
		return {}, false
	}
	r := tag_reader(pkg, tag)
	v := [3]f32{read_f32(&r), read_f32(&r), read_f32(&r)}
	return v, !r.failed
}

tag_rotator :: proc(pkg: ^Package, tag: Property_Tag) -> ([3]i32, bool) {
	if tag.size < 12 {
		return {}, false
	}
	r := tag_reader(pkg, tag)
	v := [3]i32{read_i32(&r), read_i32(&r), read_i32(&r)}
	return v, !r.failed
}

tag_f32 :: proc(pkg: ^Package, tag: Property_Tag) -> (f32, bool) {
	if tag.size < 4 {
		return 0, false
	}
	r := tag_reader(pkg, tag)
	return read_f32(&r), !r.failed
}

tag_i32 :: proc(pkg: ^Package, tag: Property_Tag) -> (i32, bool) {
	if tag.size < 4 {
		return 0, false
	}
	r := tag_reader(pkg, tag)
	return read_i32(&r), !r.failed
}

tag_name_ref :: proc(pkg: ^Package, tag: Property_Tag) -> (Name_Ref, bool) {
	if tag.size < 8 {
		return {}, false
	}
	r := tag_reader(pkg, tag)
	return read_name_ref(&r), !r.failed
}
