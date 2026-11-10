package ue3

import "core:fmt"
import "../diag"

// UShaderCache / FShaderCache (Engine/Src/ShaderCache.cpp:641 and :289) for
// package version 576:
//
//	Platform (BYTE, gate VER_GLOBAL_SHADER_FILE 538)
//	ShaderType -> DWORD map           (gate VER_FIXED_AUTO_SHADER_VERSIONING 796)
//	Shaders: count, then per shader  FName type, FGuid, SkipOffset, data
//	VertexFactoryType -> DWORD map    (538 .. 796)
//	MaterialShaderMaps: count, then per map FStaticParameterSet, SkipOffset, data
//
// The skip offsets are absolute archive positions written by the cooker. What the
// bytes between two offsets are is checked, not assumed: each shader payload starts
// with the platform byte the cache declares, a frequency byte, and carries the GUID
// and type FName of the record that names it -- the same pair the header repeats.
// Over the corpus that holds for 83,963 shaders in three platform caches (15,729
// SM2, 24,558 SM3, 43,676 SM4), 235,185,172 B of payload. The material shader map
// payloads are still skipped by offset. The compressed cache (VER_SHADER_COMPRESSION 672) and the
// automatic versioning data (796) are not present in 576; if a package ever
// carries them the reader fails instead of guessing.
Shader_Cache :: struct {
	shaders:       int,
	material_maps: int,
	payload_bytes: int, // shader payload bytes the skip offsets bound
}

read_shader_cache :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Shader_Cache, d: diag.Diagnostics) {
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
	if version >= 672 {
		diag.err(&d, "ue3.shader-cache-version", "compressed shader caches are not supported")
		return
	}
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	gaps := 0

	skip_map :: proc(r: ^Reader, stride: int) -> bool {
		count := read_i32(r)
		if r.failed || count < 0 || count > 1_000_000 {
			return false
		}
		if i64(count) * i64(stride) > i64(r.limit - r.pos) {
			return false
		}
		r.pos += int(count) * int(stride)
		return true
	}

	platform_byte := u8(0)
	_ = gaps
	if version >= 538 {
		platform_byte = read_u8(&r) // Platform
		if r.failed {
			return
		}
	}
	if version < 796 {
		if !skip_map(&r, 12) {
			diag.err(&d, "ue3.bad-shader-cache", "shader type map did not parse")
			return
		}
	}
	shaders := read_i32(&r)
	if r.failed || shaders < 0 || shaders > 10_000_000 {
		diag.err(&d, "ue3.bad-shader-cache", fmt.aprintf("implausible shader count %d", shaders))
		return
	}
	for index_of_shader in 0 ..< int(shaders) {
		if index_of_shader < 6 || index_of_shader > int(shaders) - 3 {
		}
		payload_start := r.pos
		type_ref := read_name_ref(&r) // FName type
		type_index, type_number := type_ref.index, type_ref.number
		guid_bytes := pkg.data[r.pos:r.pos + 16]
		r.pos += 16 // FGuid
		if version >= 796 {
			diag.err(&d, "ue3.shader-cache-version", "automatic shader versioning data is not supported")
			return
		}
		skip := read_i32(&r)
		if r.failed || int(skip) < r.pos || int(skip) > r.limit {
			diag.err(&d, "ue3.bad-shader-cache", "implausible shader skip offset")
			return
		}
		// The payload is an FShader (Engine/Src/ShaderManager.cpp:789): a platform
		// byte, a frequency byte, the code blob, and somewhere in it the CRC, the GUID
		// and the type FName -- the same GUID and type the header above carries.
		// Skipping to the next record is therefore not a jump over unknown bytes: the
		// two copies of the record's identity have to agree.
		payload := pkg.data[payload_start + 28:int(skip)]
		if payload[0] != platform_byte {
			diag.err(&d, "ue3.shader-platform",
				fmt.aprintf("shader %d names platform %d, the cache %d", index_of_shader, payload[0], platform_byte))
			return
		}
		if payload[1] > 1 {
			diag.err(&d, "ue3.shader-frequency",
				fmt.aprintf("shader %d names frequency %d", index_of_shader, payload[1]))
			return
		}
		if !shader_tail_ok(payload, guid_bytes, type_index, type_number, index_of_shader, &d) {
			return
		}
		result.payload_bytes += len(payload)
		r.pos = int(skip)
	}
	result.shaders = int(shaders)
	if version >= 538 && version < 796 {
		if !skip_map(&r, 12) {
			diag.err(&d, "ue3.bad-shader-cache", "vertex factory map did not parse")
			return
		}
	}
	maps := read_i32(&r)
	if r.failed || maps < 0 || maps > 1_000_000 {
		diag.err(&d, "ue3.bad-shader-cache", fmt.aprintf("implausible material shader map count %d", maps))
		return
	}
	for _ in 0 ..< int(maps) {
		if !skip_static_parameter_set(&r, version) {
			diag.err(&d, "ue3.bad-shader-cache", "material static parameter set did not parse")
			return
		}
		if version >= 660 {
			r.pos += 8 // ShaderMapVersion + ShaderMapLicenseeVersion
		}
		skip := read_i32(&r)
		if r.failed || int(skip) < r.pos || int(skip) > r.limit {
			diag.err(&d, "ue3.bad-shader-cache", "implausible material shader map skip offset")
			return
		}
		if gaps < 16 {
			gaps += 1
		}
		r.pos = int(skip)
	}
	result.material_maps = int(maps)
	if diag.has_errors(&d) && len(d.items) > 0 {
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.shader-cache-layout", fmt.aprintf("UShaderCache consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}

// shader_tail_ok checks that a payload carries the identity of its own record: the
// GUID of the header appears in it, followed by the header's type FName. It ties the
// bytes between two skip offsets to the record that names them, which a length taken
// on faith does not. The GUID does not sit at a fixed offset from the end -- the
// versioning block after it varies -- so the payload is searched for it.
shader_tail_ok :: proc(
	payload: []u8,
	guid: []u8,
	type_index, type_number: i32,
	shader: int,
	d: ^diag.Diagnostics,
) -> bool {
	at := find_bytes(payload, guid)
	if at < 0 {
		diag.err(d, "ue3.shader-guid", fmt.aprintf("shader %d payload does not repeat its GUID", shader))
		return false
	}
	if at + 16 + 8 > len(payload) {
		diag.err(d, "ue3.shader-payload", fmt.aprintf("shader %d GUID ends the payload", shader))
		return false
	}
	found := read_name_ref_at(payload, at + 16)
	if found.index != type_index || found.number != type_number {
		diag.err(d, "ue3.shader-type",
			fmt.aprintf("shader %d names type %d/%d, its payload %d/%d",
				shader, type_index, type_number, found.index, found.number))
		return false
	}
	return true
}

// find_bytes returns the first offset of needle in haystack, or -1.
find_bytes :: proc(haystack, needle: []u8) -> int {
	if len(needle) == 0 || len(haystack) < len(needle) {
		return -1
	}
	first := needle[0]
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i] != first {
			continue
		}
		if string(haystack[i:i + len(needle)]) == string(needle) {
			return i
		}
	}
	return -1
}
