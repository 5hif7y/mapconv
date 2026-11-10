package vtf

import "core:testing"
import "../diag"

// A VTF 7.2 whose mip chain has more than one level must still give back the
// largest mip: the file stores the smallest first, so a reader that walks the
// chain from the top lands past the data and reports the file as truncated. That
// is what a whole package of extracted textures hit.
@(test)
test_to_dds_reads_the_largest_mip_of_a_chain :: proc(t: ^testing.T) {
	mip0 := [32]u8{}
	mip1 := [8]u8{}
	for i in 0..<32 { mip0[i] = u8(0xA0 + i) }
	for i in 0..<8 { mip1[i] = u8(0x10 + i) }
	mips := [][]u8{mip0[:], mip1[:]} // largest first, the order the encoder takes
	encoded, ok := encode(8, 8, IMAGE_FORMAT_DXT1, mips)
	testing.expect(t, ok, "encode failed")
	d := diag.init()
	defer delete(d.items)
	dds, _, converted := to_dds(encoded, &d)
	testing.expect(t, converted, "to_dds rejected a two mip file")
	testing.expect_value(t, len(dds), 128 + 32)
	for i in 0..<32 {
		testing.expect_value(t, dds[128 + i], mip0[i])
	}
	delete(encoded)
	delete(dds)
}

// A 4x4 DXT1 VTF 7.2 with one mip: header (80 bytes) plus 8 bytes of blocks.
build_vtf :: proc() -> [dynamic]u8 {
	d: [dynamic]u8
	put :: proc(d: ^[dynamic]u8, bytes: ..u8) { append(d, ..bytes) }
	put(&d, 'V', 'T', 'F', 0)
	put(&d, 7, 0, 0, 0) // major
	put(&d, 2, 0, 0, 0) // minor
	put(&d, 80, 0) // header size
	put(&d, 4, 0) // width
	put(&d, 4, 0) // height
	put(&d, 0, 0, 0, 0) // flags
	put(&d, 1, 0) // frames
	put(&d, 0, 0) // first frame
	for _ in 0..<4 { put(&d, 0) } // padding
	for _ in 0..<12 { put(&d, 0) } // reflectivity
	for _ in 0..<4 { put(&d, 0) } // padding
	put(&d, 0, 0, 0x80, 0x3f) // bump scale 1.0
	put(&d, 13, 0, 0, 0) // DXT1
	put(&d, 1) // mip count
	put(&d, 0xff, 0xff, 0xff, 0xff) // low-res format: none
	put(&d, 0, 0) // low-res size
	for len(d) < 80 { put(&d, 0) } // rest of the header
	put(&d, 0, 0xf8, 0, 0, 0x1f, 0, 0, 0) // one DXT1 block
	return d
}

@(test)
test_vtf_to_dds :: proc(t: ^testing.T) {
	data := build_vtf()
	d := diag.init()
	defer delete(d.items)
	dds, format, ok := to_dds(data[:], &d)
	defer delete(dds)
	testing.expect(t, ok)
	testing.expect_value(t, diag.count(&d, .Error), 0)
	testing.expect_value(t, format, "DXT1")
	testing.expect_value(t, len(dds), 128 + 8)
	testing.expect_value(t, string(dds[0:4]), "DDS ")
	testing.expect_value(t, string(dds[84:88]), "DXT1")
}

@(test)
test_round_trip :: proc(t: ^testing.T) {
	mip := [8]u8{0, 0xf8, 0, 0, 0x1f, 0, 0, 0}
	mips := [][]u8{mip[:]}
	encoded, ok := encode(4, 4, IMAGE_FORMAT_DXT1, mips)
	testing.expect(t, ok)
	defer delete(encoded)
	d := diag.init()
	defer delete(d.items)
	dds, format, dds_ok := to_dds(encoded, &d)
	testing.expect(t, dds_ok)
	testing.expect_value(t, format, "DXT1")
	// DDS header is 128 bytes; the payload must match the encoded mip.
	testing.expect_value(t, len(dds), 128 + 8)
	for i in 0..<8 {
		testing.expect_value(t, dds[128 + i], mip[i])
	}
}

@(test)
test_encode_header_layout :: proc(t: ^testing.T) {
	mip := [8]u8{0, 0xf8, 0, 0, 0x1f, 0, 0, 0}
	encoded, ok := encode(4, 4, IMAGE_FORMAT_DXT1, [][]u8{mip[:]})
	testing.expect(t, ok)
	defer delete(encoded)
	// The header size is a u32 at offset 12; width/height are u16 at 16 and 18.
	testing.expect_value(t, u32(encoded[12]) | u32(encoded[13]) << 8 | u32(encoded[14]) << 16 | u32(encoded[15]) << 24, u32(80))
	testing.expect_value(t, u16(encoded[16]) | u16(encoded[17]) << 8, u16(4))
	testing.expect_value(t, u16(encoded[18]) | u16(encoded[19]) << 8, u16(4))
}

@(test)
test_encode_header_depth :: proc(t: ^testing.T) {
	mip := [8]u8{0, 0xf8, 0, 0, 0x1f, 0, 0, 0}
	encoded, ok := encode(4, 4, IMAGE_FORMAT_DXT1, [][]u8{mip[:]})
	testing.expect(t, ok)
	defer delete(encoded)
	// 7.2 header: depth is a u16 at offset 63; zero depth makes the engine
	// reject the file with "Error reading texture header".
	testing.expect_value(t, u16(encoded[63]) | u16(encoded[64]) << 8, u16(1))
}
