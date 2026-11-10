// VTF: Valve Texture Format, the texture container inside Source BSP pakfiles.
// Decodes the header and the largest mip of frame 0 / face 0 into a DDS.
package vtf

import "core:fmt"
import "../diag"


IMAGE_FORMAT_DXT1 :: 13
IMAGE_FORMAT_DXT3 :: 14
IMAGE_FORMAT_DXT5 :: 15
IMAGE_FORMAT_BGRA8888 :: 12
IMAGE_FORMAT_BGR888 :: 3
IMAGE_FORMAT_A8 :: 8
FLAG_ENVMAP :: 0x00004000

Header :: struct {
	major, minor: u32,
	header_size:  int,
	width, height: int,
	flags:        u32,
	frames:       int,
	format:       u32,
	mip_count:    int,
	depth:        int,
}

read_header :: proc(data: []u8, d: ^diag.Diagnostics) -> (h: Header, ok: bool) {
	if len(data) < 65 || data[0] != 'V' || data[1] != 'T' || data[2] != 'F' || data[3] != 0 {
		diag.err(d, "vtf.bad-signature", "not a VTF file")
		return
	}
	get_u16 :: proc(data: []u8, at: int) -> int { return int(data[at]) | int(data[at+1]) << 8 }
	get_u32 :: proc(data: []u8, at: int) -> u32 {
		return u32(data[at]) | u32(data[at+1]) << 8 | u32(data[at+2]) << 16 | u32(data[at+3]) << 24
	}
	h.major = get_u32(data, 4)
	h.minor = get_u32(data, 8)
	// 7.5 moved the fields by two bytes (headerSize becomes 32-bit); detect it
	// from the width, which is never zero in a valid file.
	shift := 0
	h.width = get_u16(data, 14)
	h.height = get_u16(data, 16)
	if h.width == 0 {
		shift = 2
		h.header_size = int(get_u32(data, 12))
		h.width = get_u16(data, 16)
		h.height = get_u16(data, 18)
	} else {
		h.header_size = get_u16(data, 12)
	}
	h.flags = get_u32(data, 18 + shift)
	h.frames = get_u16(data, 22 + shift)
	if h.frames < 1 { h.frames = 1 }
	h.format = get_u32(data, 50 + shift)
	h.mip_count = int(data[54 + shift])
	if h.mip_count < 1 { h.mip_count = 1 }
	if h.major > 7 || (h.major == 7 && h.minor >= 3) {
		h.depth = get_u16(data, 61 + shift)
		if h.depth < 1 { h.depth = 1 }
	} else { h.depth = 1 }
	if h.width == 0 || h.height == 0 {
		diag.err(d, "vtf.bad-size", "VTF has a zero dimension")
		return
	}
	return h, true
}

mip_size :: proc(format: u32, width, height: int) -> int {
	switch format {
	case IMAGE_FORMAT_DXT1:
		return max(1, (width+3)/4) * max(1, (height+3)/4) * 8
	case IMAGE_FORMAT_DXT3, IMAGE_FORMAT_DXT5:
		return max(1, (width+3)/4) * max(1, (height+3)/4) * 16
	case IMAGE_FORMAT_BGRA8888:
		return width*height*4
	case IMAGE_FORMAT_BGR888:
		return width*height*3
	case IMAGE_FORMAT_A8:
		return width*height
	}
	return 0
}

to_dds :: proc(data: []u8, d: ^diag.Diagnostics) -> (out: []u8, format_name: string, ok: bool) {
	h, header_ok := read_header(data, d)
	if !header_ok { return }
	if h.frames > 1 || h.depth > 1 {
		diag.warn(d, "vtf.unsupported-layout", "animated/volumetric VTFs: using frame 0")
	}
	top := mip_size(h.format, h.width, h.height)
	if top == 0 {
		diag.warn(d, "vtf.unsupported-format", fmt.aprintf("image format %d is not supported", h.format))
		return
	}
	if h.header_size <= 0 || h.header_size > len(data) {
		diag.err(d, "vtf.bad-header-size", "VTF header size is outside the file")
		return
	}
	// A VTF stores the mip chain smallest first, so the largest mip is the last
	// one: everything the smaller mips take comes before it. Reading the other way
	// round worked only for single-mip files and reported the rest as truncated.
	smaller := 0
	w, hh := h.width, h.height
	for mip := 1; mip < h.mip_count; mip += 1 {
		w = max(1, w/2); hh = max(1, hh/2)
		size := mip_size(h.format, w, hh)
		if size == 0 {
			break
		}
		smaller += size
	}
	offset := h.header_size + smaller
	if offset + top > len(data) {
		diag.err(d, "vtf.truncated", "VTF mip data is shorter than declared")
		return
	}
	buf := make([dynamic]u8, 0, 128+top)
	append(&buf, ..transmute([]u8)string("DDS "))
	append_u32(&buf, 124)
	append_u32(&buf, 0x00081007)
	append_u32(&buf, u32(h.height))
	append_u32(&buf, u32(h.width))
	append_u32(&buf, u32(top))
	append_u32(&buf, 0)
	append_u32(&buf, 0)
	for _ in 0..<11 { append_u32(&buf, 0) }
	append_u32(&buf, 32)
	switch h.format {
	case IMAGE_FORMAT_DXT1, IMAGE_FORMAT_DXT3, IMAGE_FORMAT_DXT5:
		fourcc := "DXT1"
		if h.format == IMAGE_FORMAT_DXT3 { fourcc = "DXT3" }
		if h.format == IMAGE_FORMAT_DXT5 { fourcc = "DXT5" }
		format_name = fourcc
		append_u32(&buf, 0x4)
		append(&buf, ..transmute([]u8)fourcc)
		for _ in 0..<5 { append_u32(&buf, 0) }
	case IMAGE_FORMAT_BGRA8888:
		format_name = "BGRA8"
		append_u32(&buf, 0x41); append_u32(&buf, 0); append_u32(&buf, 32)
		append_u32(&buf, 0x00ff0000); append_u32(&buf, 0x0000ff00)
		append_u32(&buf, 0x000000ff); append_u32(&buf, 0xff000000)
	case IMAGE_FORMAT_BGR888:
		format_name = "BGR888"
		append_u32(&buf, 0x40); append_u32(&buf, 0); append_u32(&buf, 24)
		append_u32(&buf, 0x00ff0000); append_u32(&buf, 0x0000ff00)
		append_u32(&buf, 0x000000ff); append_u32(&buf, 0)
	case IMAGE_FORMAT_A8:
		format_name = "A8"
		append_u32(&buf, 0x20000); append_u32(&buf, 0); append_u32(&buf, 8)
		append_u32(&buf, 0xff); append_u32(&buf, 0); append_u32(&buf, 0); append_u32(&buf, 0)
	}
	append_u32(&buf, 0x1000)
	for _ in 0..<4 { append_u32(&buf, 0) }
	append(&buf, ..data[offset:offset+top])
	return buf[:], format_name, true
}

append_u32 :: proc(buf: ^[dynamic]u8, value: u32) {
	append(buf, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

// Encode a minimal 7.2 VTF: 80-byte header, no low-res image, mips written
// smallest first as the format requires. Input mips are largest first and must
// be complete (DXT1/3/5).
encode :: proc(width, height: int, format: u32, mips: [][]u8) -> (out: []u8, ok: bool) {
	if width <= 0 || height <= 0 || len(mips) == 0 {
		return
	}
	// DXT blocks are 4x4; Source rejects mips smaller than one full block.
	max_mips := 1
	if format == IMAGE_FORMAT_DXT1 || format == IMAGE_FORMAT_DXT3 || format == IMAGE_FORMAT_DXT5 {
		for (width >> uint(max_mips)) >= 4 && (height >> uint(max_mips)) >= 4 {
			max_mips += 1
		}
	} else {
		max_mips = len(mips)
	}
	keep := min(len(mips), max_mips)
	buf := make([dynamic]u8, 0, 80 + 64 * 1024)
	append(&buf, 'V', 'T', 'F', 0)
	append_u32(&buf, 7)
	append_u32(&buf, 2)
	append_u32(&buf, 80) // header size
	append(&buf, u8(width), u8(width >> 8), u8(height), u8(height >> 8))
	append_u32(&buf, 0) // flags
	append(&buf, 1, 0, 0, 0) // frames, first frame
	for _ in 0..<4 { append(&buf, 0) } // padding
	for _ in 0..<12 { append(&buf, 0) } // reflectivity
	for _ in 0..<4 { append(&buf, 0) } // padding
	append_u32(&buf, 0x3f800000) // bump scale 1.0
	append_u32(&buf, format)
	append(&buf, u8(keep), 0xff, 0xff, 0xff, 0xff) // mip count, low-res none
	append(&buf, 0, 0) // low-res width/height
	append(&buf, 1, 0) // depth
	for len(buf) < 80 { append(&buf, 0) }
	for i := keep - 1; i >= 0; i -= 1 {
		append(&buf, ..mips[i])
	}
	return buf[:], true
}

// from_dds reads a DDS file and returns the mip chain a VTF needs. UModel
// exports a single, full-resolution mip, which is enough for Source: the engine
// builds the rest. Supports DXT1/3/5 and BGRA8.
from_dds :: proc(data: []u8) -> (width, height: int, format: u32, mips: [][]u8, ok: bool) {
	if len(data) < 128 || data[0] != 'D' || data[1] != 'D' || data[2] != 'S' || data[3] != ' ' {
		return
	}
	h := int(read_u32(data, 12))
	w := int(read_u32(data, 16))
	if w <= 0 || h <= 0 {
		return
	}
	count := int(read_u32(data, 28))
	if count == 0 {
		count = 1
	}
	block := 0
	switch {
	case data[84]=='D' && data[85]=='X' && data[86]=='T' && data[87]=='1':
		format, block = IMAGE_FORMAT_DXT1, 8
	case data[84]=='D' && data[85]=='X' && data[86]=='T' && data[87]=='3':
		format, block = IMAGE_FORMAT_DXT3, 16
	case data[84]=='D' && data[85]=='X' && data[86]=='T' && data[87]=='5':
		format, block = IMAGE_FORMAT_DXT5, 16
	case:
		return
	}
	mips = make([][]u8, count)
	pos := 128
	for i in 0..<count {
		mw := max(1, w >> uint(i))
		mh := max(1, h >> uint(i))
		size := max(1, (mw + 3) / 4) * max(1, (mh + 3) / 4) * block
		if pos + size > len(data) {
			// Truncated chain: keep what is available as a single mip.
			if i == 0 {
				return
			}
			mips = mips[:i]
			break
		}
		mips[i] = data[pos:pos + size]
		pos += size
	}
	return w, h, format, mips, true
}

read_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at+1]) << 8 | u32(data[at+2]) << 16 | u32(data[at+3]) << 24
}
