// Texture2D: properties, mip chain and DDS export.
//
// UTexture2D::Serialize writes the tagged properties, then UTexture's SourceArt
// bulk data, then the mip array. Each FTexture2DMipMap is a bulk-data record
// followed by its dimensions. Cooked maps may store mips inline (bulk flags 0)
// or streamed into a texture file cache (BULKDATA_StoreInSeparateFile); the
// latter cannot be read without the .tfc, and is reported with its cache name,
// offset and size so a later pass can resolve it.
package ue3

import "core:fmt"
import "core:strings"
import "../diag"

BULKDATA_STORE_IN_SEPARATE_FILE :: 0x01
BULKDATA_UNUSED :: 0x20

Bulk_Header :: struct {
	flags:  u32,
	count:  i32,
	size:   i32,
	offset: i32,
}

Texture_Mip :: struct {
	width:  i32,
	height: i32,
	// Inline mip bytes. Empty when the mip lives in a separate file.
	data:   []u8,
	flags:  u32,
	offset: i32,
	size:   i32,
}

Texture :: struct {
	export_index: int,
	width:        i32,
	height:       i32,
	format:       string, // PF_* name, e.g. PF_DXT5
	mips:         []Texture_Mip,
	// Cache name, when the mips are streamed.
	cache_name:   string,
	streamed:     int,
}

// read_bulk_header reads the common FUntypedBulkData prefix.
read_bulk_data_header :: proc(r: ^Reader) -> (Bulk_Header, bool) {
	h := Bulk_Header {
		flags  = read_u32(r),
		count  = read_i32(r),
		size   = read_i32(r),
		offset = read_i32(r),
	}
	if r.failed || h.size < 0 {
		return {}, false
	}
	return h, true
}

read_texture :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (texture: Texture, d: diag.Diagnostics) {
	d = diag.init()
	texture.export_index = export_index
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
	if tag, ok := find_tag(pkg, head.tags, "SizeX"); ok {
		texture.width, _ = tag_i32(pkg, tag)
	}
	if tag, ok := find_tag(pkg, head.tags, "SizeY"); ok {
		texture.height, _ = tag_i32(pkg, tag)
	}
	if tag, ok := find_tag(pkg, head.tags, "Format"); ok {
		if ref, ok2 := tag_name_ref(pkg, tag); ok2 {
			texture.format = name_text(pkg, ref)
		}
	}
	if tag, ok := find_tag(pkg, head.tags, "TextureFileCacheName"); ok {
		if ref, ok2 := tag_name_ref(pkg, tag); ok2 {
			texture.cache_name = name_text(pkg, ref)
		}
	}

	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	// SourceArt: a bulk record (usually empty in cooked packages).
	source, ok := read_bulk_data_header(&r)
	if !ok {
		diag.err(&d, "ue3.truncated", r.message)
		return
	}
	if source.flags & BULKDATA_STORE_IN_SEPARATE_FILE == 0 {
		if !need(&r, int(source.size)) {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		r.pos += int(source.size)
	}

	mip_count := read_i32(&r)
	if r.failed || mip_count < 0 || mip_count > 64 {
		diag.err(&d, "ue3.bad-texture", fmt.aprintf("implausible mip count %d", mip_count))
		return
	}
	texture.mips = make([]Texture_Mip, int(mip_count), allocator)
	for i in 0..<int(mip_count) {
		bulk, ok2 := read_bulk_data_header(&r)
		if !ok2 {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		mip := Texture_Mip {
			flags  = bulk.flags,
			offset = bulk.offset,
			size   = bulk.size,
		}
		if bulk.flags & BULKDATA_STORE_IN_SEPARATE_FILE != 0 {
			texture.streamed += 1
		} else if bulk.size > 0 {
			if !need(&r, int(bulk.size)) {
				diag.err(&d, "ue3.truncated", r.message)
				return
			}
			mip.data = pkg.data[r.pos:r.pos + int(bulk.size)]
			r.pos += int(bulk.size)
		}
		mip.width = read_i32(&r)
		mip.height = read_i32(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		texture.mips[i] = mip
	}
	if texture.streamed > 0 {
		diag.info(
			&d,
			"ue3.texture-streamed",
			fmt.aprintf(
				"%d of %d mip(s) live in the texture cache %q (offset %d, %d bytes); only inline mips can be extracted",
				texture.streamed,
				len(texture.mips),
				texture.cache_name,
				texture.mips[0].offset,
				texture.mips[0].size,
			),
			name_text(pkg, e.object_name),
		)
	}
	return
}

// DDS_INFO maps a UE3 pixel format name to the DDS pixel format.
Dds_Format :: enum {
	Unknown,
	DXT1,
	DXT3,
	DXT5,
	BGRA8,
	G8,
	A8,
	RGBA16F,
}

dds_format :: proc(name: string) -> Dds_Format {
	switch strings.to_upper(name) {
	case "PF_DXT1":
		return .DXT1
	case "PF_DXT3":
		return .DXT3
	case "PF_DXT5":
		return .DXT5
	case "PF_A8R8G8B8", "PF_B8G8R8A8":
		return .BGRA8
	case "PF_G8", "PF_L8":
		return .G8
	case "PF_A8":
		return .A8
	case "PF_FLOAT_RGBA16":
		return .RGBA16F
	}
	return .Unknown
}

// dds_bytes builds a DDS file for a texture's leading inline mips. Returns nil
// when the format is unsupported or the first mip is streamed.
dds_bytes :: proc(texture: ^Texture) -> ([]u8, bool) {
	format := dds_format(texture.format)
	if format == .Unknown {
		return nil, false
	}
	// The largest mips may be streamed; the longest inline run starting at the
	// first available mip still yields a valid (lower-resolution) DDS.
	first := 0
	for first < len(texture.mips) && len(texture.mips[first].data) == 0 {
		first += 1
	}
	if first >= len(texture.mips) {
		return nil, false
	}
	inline_count := 0
	for mip in texture.mips[first:] {
		if len(mip.data) == 0 {
			break
		}
		inline_count += 1
	}
	width := texture.mips[first].width
	height := texture.mips[first].height
	linear := width * height
	#partial switch format {
	case .DXT1:
		linear = max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * 8
	case .DXT3, .DXT5:
		linear = max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * 16
	case .BGRA8:
		linear = width * height * 4
	case .G8:
		linear = width * height
	case:
		linear = width * height
	}

	out := make([dynamic]u8, 0, 128 + 64 * 1024)
	append(&out, ..transmute([]u8)string("DDS "))
	append_u32(&out, 124) // dwSize
	append_u32(&out, 0x00021007) // CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE|MIPMAPCOUNT
	append_u32(&out, u32(height))
	append_u32(&out, u32(width))
	append_u32(&out, u32(linear)) // linear size of the first written mip
	append_u32(&out, 0) // depth
	append_u32(&out, u32(inline_count))
	for _ in 0..<11 {
		append_u32(&out, 0) // reserved
	}
	// DDS_PIXELFORMAT: eight u32 fields.
	append_u32(&out, 32) // dwSize
	switch format {
	case .DXT1, .DXT3, .DXT5:
		fourcc: string
		#partial switch format {
		case .DXT1:
			fourcc = "DXT1"
		case .DXT3:
			fourcc = "DXT3"
		case .DXT5:
			fourcc = "DXT5"
		case:
			fourcc = "DXT1"
		}
		append_u32(&out, 0x4) // DDPF_FOURCC
		append(&out, ..transmute([]u8)fourcc)
		append_u32(&out, 0) // rgb bit count
		append_u32(&out, 0)
		append_u32(&out, 0)
		append_u32(&out, 0)
		append_u32(&out, 0)
	case .BGRA8:
		append_u32(&out, 0x41) // RGB | ALPHAPIXELS
		append_u32(&out, 0) // fourcc
		append_u32(&out, 32)
		append_u32(&out, 0x00ff0000) // R
		append_u32(&out, 0x0000ff00) // G
		append_u32(&out, 0x000000ff) // B
		append_u32(&out, 0xff000000) // A
	case .G8:
		append_u32(&out, 0x20000) // DDPF_LUMINANCE
		append_u32(&out, 0)
		append_u32(&out, 8)
		append_u32(&out, 0xff)
		append_u32(&out, 0)
		append_u32(&out, 0)
		append_u32(&out, 0)
	case .A8:
		append_u32(&out, 0x2) // DDPF_ALPHA
		append_u32(&out, 0)
		append_u32(&out, 8)
		append_u32(&out, 0)
		append_u32(&out, 0)
		append_u32(&out, 0)
		append_u32(&out, 0xff)
	case .RGBA16F:
		return nil, false
	case .Unknown:
		return nil, false
	}
	// caps: TEXTURE | COMPLEX, plus MIPMAP when there is more than one mip.
	caps := u32(0x1008)
	if inline_count > 1 {
		caps |= 0x400000
	}
	append_u32(&out, caps)
	append_u32(&out, 0) // caps2
	append_u32(&out, 0) // caps3
	append_u32(&out, 0) // caps4
	append_u32(&out, 0) // reserved2

	for i in 0..<inline_count {
		append(&out, ..texture.mips[first + i].data)
	}
	return out[:], true
}

append_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}
