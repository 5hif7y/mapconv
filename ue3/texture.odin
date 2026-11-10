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
BULKDATA_COMPRESSED :: 0x10

Bulk_Header :: struct {
	flags:  u32,
	count:  i32,
	size:   i32,
	offset: i32,
}

Texture_Mip :: struct {
	width:  i32,
	height: i32,
	uncompressed: i32,
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
	// cube_tail is set when the sixteen byte texture cube record at the end of a
	// cube was consumed: twelve reserved bytes and the streamed mip offset.
	cube_tail:    bool,
	cube_offset:  i32,
}

// read_bulk_header reads the common FUntypedBulkData prefix.
read_bulk_data_header :: proc(r: ^Reader) -> (Bulk_Header, bool) {
	h := Bulk_Header {
		flags  = read_u32(r),
		count  = read_i32(r),
		size   = read_i32(r),
		offset = read_i32(r),
	}
	if r.failed {
		return {}, false
	}
	if h.size < 0 {
		// Streamed textures can carry an "unused" placeholder mip: flags 0x20
		// with size and offset set to -1. It holds no data but the mip
		// dimensions still follow, so treating it as an error truncates the
		// whole texture (the case of every *_art package mip chain).
		if h.flags & 0x20 != 0 && h.size == -1 {
			h.count = 0
			h.size = 0
			h.offset = 0
			return h, true
		}
		return {}, false
	}
	return h, true
}


// decompress_mip decodes a UE3 compressed bulk block: an FCompressedChunkHeader
// (tag, block size, total sizes, per-block sizes) followed by LZO streams.
decompress_mip :: proc(src: []u8, expected: int) -> ([]u8, bool) {
	if len(src) < 16 || expected <= 0 {
		return nil, false
	}
	pos := 0
	tag := u32(src[0]) | u32(src[1]) << 8 | u32(src[2]) << 16 | u32(src[3]) << 24
	if tag == 0x9E2A83C1 {
		pos = 4
	}
	if pos + 12 > len(src) {
		return nil, false
	}
	block_size := int(i32(u32(src[pos]) | u32(src[pos+1]) << 8 | u32(src[pos+2]) << 16 | u32(src[pos+3]) << 24))
	pos += 4
	if block_size <= 0 {
		block_size = 0x20000
	}
	sum_comp := int(i32(u32(src[pos]) | u32(src[pos+1]) << 8 | u32(src[pos+2]) << 16 | u32(src[pos+3]) << 24))
	pos += 4
	sum_uncomp := int(i32(u32(src[pos]) | u32(src[pos+1]) << 8 | u32(src[pos+2]) << 16 | u32(src[pos+3]) << 24))
	pos += 4
	if sum_uncomp != expected {
		return nil, false
	}

	out := make([]u8, expected, context.allocator)
	// The block table is contiguous: every (compressed, uncompressed) pair is
	// written first and the LZO streams follow it. Reading a stream right after
	// its own 8-byte header only works for single-block mips.
	Block :: struct {
		compressed:   int,
		uncompressed: int,
	}
	blocks := make([dynamic]Block, 0, 8, context.allocator)
	defer delete(blocks)
	sum_c, sum_u := 0, 0
	for sum_u < sum_uncomp {
		if pos + 8 > len(src) {
			return nil, false
		}
		bc := int(i32(u32(src[pos]) | u32(src[pos+1]) << 8 | u32(src[pos+2]) << 16 | u32(src[pos+3]) << 24))
		pos += 4
		bu := int(i32(u32(src[pos]) | u32(src[pos+1]) << 8 | u32(src[pos+2]) << 16 | u32(src[pos+3]) << 24))
		pos += 4
		if bc <= 0 || bu <= 0 || bc > len(src) || bu > expected {
			return nil, false
		}
		append(&blocks, Block{bc, bu})
		sum_c += bc
		sum_u += bu
	}
	if sum_u != sum_uncomp || sum_c != sum_comp {
		return nil, false
	}
	op := 0
	for block in blocks {
		if pos + block.compressed > len(src) || op + block.uncompressed > expected {
			return nil, false
		}
		n, ok := lzo1x_decompress(src[pos:pos+block.compressed], out[op:op+block.uncompressed])
		if !ok || n != block.uncompressed {
			return nil, false
		}
		pos += block.compressed
		op += block.uncompressed
	}
	if op != expected {
		return nil, false
	}
	return out, true
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
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller: deleting them here and
		// again in the caller is a double free that kills the process.
		d = head_d
		return
	}
	defer delete(head_d.items)
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
			flags        = bulk.flags,
			offset       = bulk.offset,
			size         = bulk.size,
			uncompressed = bulk.count,
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
			if bulk.flags & BULKDATA_COMPRESSED != 0 {
				if decoded, decoded_ok := decompress_mip(mip.data, int(bulk.count)); decoded_ok {
					mip.data = decoded
				} else {
					// Never expose the compressed bytes as if they were DXT
					// data: that is what produced noisy full-res textures.
					// Dropping the mip lets the exporter fall back to the
					// smaller inline chain, which is intact.
					mip.data = nil
				}
			}
		}
		mip.width = read_i32(&r)
		mip.height = read_i32(&r)
		if r.failed {
			diag.err(&d, "ue3.truncated", r.message)
			return
		}
		texture.mips[i] = mip
	}
	// A texture cube ends with a sixteen byte record after the mip chain: twelve
	// reserved bytes and the offset of its mips when they live outside the file.
	if strings.has_suffix(export_class_name(pkg, e), "Cube") {
		left := head.end_offset - r.pos
		if left == 16 {
			zeros := true
			for i in 0 ..< 12 {
				if pkg.data[r.pos + i] != 0 {
					zeros = false
				}
			}
			if zeros {
				r.pos += 12
				offset := read_i32(&r)
				if !r.failed && offset > 0 {
					texture.cube_tail = true
					texture.cube_offset = offset
				}
			}
		}
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

// read_texture_cube covers the texture cube body. Unlike a texture 2D it carries
// no source art bytes and no inline mip chain: sixteen bytes that are the
// FUntypedBulkData header of the stripped source art, with the first three words
// zero and the recorded file offset equal to the export's own offset, which is
// where the bulk data lived before cooking removed it.
read_texture_cube :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (streamed_offset: i32, d: diag.Diagnostics) {
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
	if head.end_offset - head.body_offset != 16 {
		diag.err(&d, "ue3.bad-texture", fmt.aprintf("cube body is %d bytes, expected 16", head.end_offset - head.body_offset))
		return
	}
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	for i in 0 ..< 12 {
		if read_u8(&r) != 0 {
			diag.err(&d, "ue3.bad-texture", fmt.aprintf("cube record byte %d is not reserved", i))
			return
		}
	}
	// The recorded offset must point inside the package, after the export header:
	// that is where the stripped source art was written before cooking.
	offset := read_i32(&r)
	// The offset points at the end of the package when the cooker stripped the
	// source art of the last export: it records where the data would have been.
	if r.failed || offset <= e.serial_offset || i64(offset) > i64(len(pkg.data)) {
		diag.err(&d, "ue3.bad-texture", fmt.aprintf("cube record offset %d is outside the export range [%d, %d)", offset, e.serial_offset, len(pkg.data)))
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.bad-texture", "cube record did not end with the export")
		return
	}
	streamed_offset = offset
	return
}

// read_shadow_map_1d covers the SpeedTree shadow map: a sample count, one float
// per sample and the sixteen byte light case guid. Measured on the single object
// of the corpus: 414 samples, then the guid, and the body ends exactly there.
read_shadow_map_1d :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (samples: int, d: diag.Diagnostics) {
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
	count := read_i32(&r)
	if r.failed || count <= 0 || count > 65_536 {
		diag.err(&d, "ue3.bad-texture", fmt.aprintf("implausible shadow sample count %d", count))
		return
	}
	for i in 0 ..< int(count) {
		value := read_f32(&r)
		if !(value == value) || value > 1e30 || value < -1e30 {
			diag.err(&d, "ue3.bad-texture", fmt.aprintf("shadow sample %d is not finite", i))
			return
		}
	}
	if head.end_offset - r.pos != 16 {
		diag.err(&d, "ue3.bad-texture", fmt.aprintf("shadow map leaves %d bytes for the guid", head.end_offset - r.pos))
		return
	}
	r.pos += 16
	samples = int(count)
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
