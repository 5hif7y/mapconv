package ue3

import "core:testing"
import "../diag"

// Synthetic actor: RF_HasStack export with a 22-byte state frame (no Node, so no
// code offset), the NetIndex and three tagged properties.

put_u16 :: proc(b: ^Builder, v: u16) {
	append(&b.buf, u8(v), u8(v >> 8))
}

put_tag_header :: proc(b: ^Builder, name_index, type_index: i32, size: i32, array_index: i32) {
	put_i32(b, name_index)
	put_i32(b, 0)
	put_i32(b, type_index)
	put_i32(b, 0)
	put_i32(b, size)
	put_i32(b, array_index)
}

build_actor_payload :: proc() -> [dynamic]u8 {
	// Name indices as laid out by build_actor_package.
	NAME_LOCATION :: 6
	NAME_STRUCT :: 7
	NAME_VECTOR :: 8
	NAME_ROTATION :: 9
	NAME_ROTATOR :: 10
	NAME_DRAWSCALE :: 11
	NAME_FLOAT :: 12

	p := Builder{}
	// State frame: Node, StateNode, ProbeMask, LatentAction (WORD), StateStack.
	put_i32(&p, 0) // Node
	put_i32(&p, 0) // StateNode
	put_u64(&p, 0) // ProbeMask
	put_u16(&p, 0) // LatentAction (WORD)
	put_i32(&p, 0) // StateStack count

	put_i32(&p, 1) // NetIndex

	put_tag_header(&p, NAME_LOCATION, NAME_STRUCT, 12, 0)
	put_name_ref(&p, NAME_VECTOR, 0)
	put_f32(&p, 10)
	put_f32(&p, 20)
	put_f32(&p, 30)

	put_tag_header(&p, NAME_ROTATION, NAME_STRUCT, 12, 0)
	put_name_ref(&p, NAME_ROTATOR, 0)
	put_i32(&p, 16384)
	put_i32(&p, 0)
	put_i32(&p, 8192)

	put_tag_header(&p, NAME_DRAWSCALE, NAME_FLOAT, 4, 0)
	put_f32(&p, 2.5)

	put_i32(&p, 0) // "None" terminator
	put_i32(&p, 0)
	return p.buf
}

build_actor_package :: proc(class_name: string, payload: []u8, flags: u64) -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	// 0..5 fixed, then the actor names used by build_actor_payload.
	for text in ([]string{"None", "Class", "Package", "Engine", class_name, "Actor_0", "Location", "StructProperty", "Vector", "Rotation", "Rotator", "DrawScale", "FloatProperty", "Brightness", "LightColor", "Color"}) {
		put_name_entry(&nb, text, 0)
	}
	names_buf = nb.buf

	imports_buf: [dynamic]u8
	ib := Builder{buf = imports_buf}
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, 0)
	put_name_ref(&ib, 3, 0)
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1)
	put_name_ref(&ib, 4, 0) // the actor class
	imports_buf = ib.buf

	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(names_buf)
	export_offset := import_offset + len(imports_buf)
	payload_offset := export_offset + 68
	depends_offset := payload_offset + len(payload)

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	put_i32(&eb, -2) // class = import 1
	put_i32(&eb, 0)
	put_i32(&eb, 0)
	put_name_ref(&eb, 5, 0)
	put_i32(&eb, 0)
	put_u64(&eb, flags)
	put_i32(&eb, i32(len(payload)))
	put_i32(&eb, i32(payload_offset))
	put_u32(&eb, 0)
	put_i32(&eb, 0)
	put_guid(&eb)
	put_u32(&eb, 0)
	exports_buf = eb.buf

	out: [dynamic]u8
	h := Builder{buf = out}
	put_u32(&h, PACKAGE_FILE_TAG)
	put_u32(&h, 0x00050240)
	put_i32(&h, i32(header_fixed))
	put_fstring(&h, "")
	put_u32(&h, PKG_COOKED)
	put_i32(&h, 16)
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1)
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2)
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 1)
	put_i32(&h, 16)
	put_i32(&h, 0)
	put_i32(&h, 4701)
	put_i32(&h, 87)
	put_u32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	append(&h.buf, ..names_buf[:])
	append(&h.buf, ..imports_buf[:])
	append(&h.buf, ..exports_buf[:])
	append(&h.buf, ..payload)
	return h.buf
}

@(test)
test_read_actor_transform :: proc(t: ^testing.T) {
	payload := build_actor_payload()
	data := build_actor_package("StaticMeshActor", payload[:], RF_HAS_STACK)
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)

	head, head_d := read_object_head(&pkg, pkg.exports[0])
	defer delete(head_d.items)
	testing.expect_value(t, diag.count(&head_d, .Error), 0)
	testing.expect(t, head.has_state_frame)
	testing.expect_value(t, head.state_frame.node, i32(0))
	testing.expect_value(t, head.state_frame.state_stack_count, i32(0))
	testing.expect_value(t, head.net_index, i32(1))
	testing.expect_value(t, len(head.tags), 3)

	info, info_d := read_actor_info(&pkg, 0)
	defer delete(info_d.items)
	testing.expect_value(t, diag.count(&info_d, .Error), 0)
	testing.expect_value(t, info.class_name, "StaticMeshActor")
	testing.expect(t, info.has_location)
	testing.expect_value(t, info.location[0], f32(10))
	testing.expect_value(t, info.location[2], f32(30))
	testing.expect(t, info.has_rotation)
	testing.expect_value(t, info.rotation[0], i32(16384))
	testing.expect_value(t, info.rotation[2], i32(8192))
	testing.expect(t, info.has_draw_scale)
	testing.expect_value(t, info.draw_scale, f32(2.5))
}

@(test)
test_component_template_prefix :: proc(t: ^testing.T) {
	// Components write UComponent::PreSerialize's template owner class before the
	// NetIndex. The class name is what distinguishes them.
	p := Builder{}
	put_i32(&p, 7) // template owner class
	put_i32(&p, 0) // NetIndex
	put_i32(&p, 0) // None
	put_i32(&p, 0)
	data := build_actor_package("CylinderComponent", p.buf[:], 0)
	pkg, d := parse(data[:])
	defer delete(d.items)

	head, head_d := read_object_head(&pkg, pkg.exports[0])
	defer delete(head_d.items)
	testing.expect_value(t, diag.count(&head_d, .Error), 0)
	testing.expect(t, head.has_template_owner)
	testing.expect_value(t, head.template_owner_class, i32(7))
	testing.expect_value(t, head.net_index, i32(0))
	testing.expect_value(t, len(head.tags), 0)
}

build_light_actor_payload :: proc() -> [dynamic]u8 {
	NAME_BRIGHTNESS :: 13
	NAME_FLOAT :: 12
	NAME_LIGHTCOLOR :: 14
	NAME_STRUCT :: 7
	NAME_COLOR :: 15

	p := Builder{}
	// State frame without a Node (22 bytes).
	put_i32(&p, 0)
	put_i32(&p, 0)
	put_u64(&p, 0)
	put_u16(&p, 0)
	put_i32(&p, 0)
	put_i32(&p, 1) // NetIndex

	put_tag_header(&p, NAME_BRIGHTNESS, NAME_FLOAT, 4, 0)
	put_f32(&p, 3.5)

	put_tag_header(&p, NAME_LIGHTCOLOR, NAME_STRUCT, 4, 0)
	put_name_ref(&p, NAME_COLOR, 0)
	append(&p.buf, 10, 20, 30, 255) // B, G, R, A

	put_i32(&p, 0) // None
	put_i32(&p, 0)
	return p.buf
}

@(test)
test_read_light_actor :: proc(t: ^testing.T) {
	payload := build_light_actor_payload()
	data := build_actor_package("PointLight", payload[:], RF_HAS_STACK)
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)

	info, info_d := read_actor_info(&pkg, 0)
	defer delete(info_d.items)
	testing.expect_value(t, diag.count(&info_d, .Error), 0)
	testing.expect(t, info.has_brightness)
	testing.expect_value(t, info.brightness, f32(3.5))
	testing.expect(t, info.has_light_color)
	testing.expect_value(t, info.light_color[0], u8(10)) // B
	testing.expect_value(t, info.light_color[2], u8(30)) // R
	testing.expect_value(t, info.light_color[3], u8(255)) // A
}
