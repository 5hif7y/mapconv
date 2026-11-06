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

// Object_Head is the shared prelude of an export payload.
Object_Head :: struct {
	net_index:   i32,
	tags:        []Property_Tag,
	// Absolute file offset of the native class data (after the "None" tag).
	body_offset: int,
	// Absolute end of this export's payload (SerialOffset + SerialSize).
	end_offset:  int,
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
	head.net_index = read_i32(&r)
	if r.failed {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}

	tags := make([dynamic]Property_Tag, 0, 4, allocator)
	version := engine_version(&pkg.summary)
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
