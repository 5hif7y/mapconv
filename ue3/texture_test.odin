package ue3

import "core:testing"
import "../diag"

build_texture_payload :: proc(streamed: bool) -> [dynamic]u8 {
	// Name indices from build_texture_package.
	NAME_SIZEX :: 6
	NAME_INT :: 7
	NAME_SIZEY :: 8
	NAME_FORMAT :: 9
	NAME_BYTE :: 10
	NAME_DXT1 :: 11

	p := Builder{}
	put_i32(&p, 1) // NetIndex

	put_tag_header(&p, NAME_SIZEX, NAME_INT, 4, 0)
	put_i32(&p, 4)
	put_tag_header(&p, NAME_SIZEY, NAME_INT, 4, 0)
	put_i32(&p, 4)
	put_tag_header(&p, NAME_FORMAT, NAME_BYTE, 8, 0)
	put_name_ref(&p, NAME_DXT1, 0)
	put_i32(&p, 0) // None
	put_i32(&p, 0)

	// SourceArt bulk: empty, inline.
	put_u32(&p, 0) // flags
	put_i32(&p, 0) // count
	put_i32(&p, 0) // size
	put_i32(&p, 0) // offset (unused when size is 0)

	put_i32(&p, 1) // mip count
	// One DXT1 4x4 mip: 8 bytes.
	put_u32(&p, streamed ? 1 : 0)
	put_i32(&p, 8)
	put_i32(&p, 8)
	put_i32(&p, 0) // offset patched by the engine on load; ignored when inline
	if !streamed {
		for _ in 0..<8 {
			append(&p.buf, 0xAB)
		}
	}
	put_i32(&p, 4) // SizeX
	put_i32(&p, 4) // SizeY
	return p.buf
}

build_texture_package :: proc(payload: []u8) -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "Texture2D", "T_test", "SizeX", "IntProperty", "SizeY", "Format", "ByteProperty", "PF_DXT1"}) {
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
	put_name_ref(&ib, 4, 0)
	imports_buf = ib.buf

	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(names_buf)
	export_offset := import_offset + len(imports_buf)
	payload_offset := export_offset + 68
	depends_offset := payload_offset + len(payload)

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	put_i32(&eb, -2)
	put_i32(&eb, 0)
	put_i32(&eb, 0)
	put_name_ref(&eb, 5, 0)
	put_i32(&eb, 0)
	put_u64(&eb, 0)
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
	put_i32(&h, 12)
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1)
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2)
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 1)
	put_i32(&h, 12)
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
test_read_texture_and_dds :: proc(t: ^testing.T) {
	payload := build_texture_payload(false)
	data := build_texture_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)

	texture, tex_d := read_texture(&pkg, 0)
	defer delete(tex_d.items)
	testing.expect_value(t, diag.count(&tex_d, .Error), 0)
	testing.expect_value(t, texture.width, i32(4))
	testing.expect_value(t, texture.height, i32(4))
	testing.expect_value(t, texture.format, "PF_DXT1")
	testing.expect_value(t, len(texture.mips), 1)
	testing.expect_value(t, len(texture.mips[0].data), 8)
	testing.expect_value(t, texture.streamed, 0)

	bytes, ok := dds_bytes(&texture)
	testing.expect(t, ok)
	testing.expect_value(t, len(bytes), 136)
	testing.expect_value(t, string(bytes[0:4]), "DDS ")
	testing.expect_value(t, string(bytes[84:88]), "DXT1")
	testing.expect_value(t, bytes[128], u8(0xAB))
}

@(test)
test_streamed_mip_is_reported :: proc(t: ^testing.T) {
	payload := build_texture_payload(true)
	data := build_texture_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	texture, tex_d := read_texture(&pkg, 0)
	defer delete(tex_d.items)
	testing.expect_value(t, diag.count(&tex_d, .Error), 0)
	testing.expect_value(t, texture.streamed, 1)
	_, ok := dds_bytes(&texture)
	testing.expect(t, !ok)
}
