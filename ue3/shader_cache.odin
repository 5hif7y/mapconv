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
// The skip offsets are absolute archive positions written by the cooker, so the
// shader and material shader map payloads are consumed exactly without decoding
// shader bytecode. The compressed cache (VER_SHADER_COMPRESSION 672) and the
// automatic versioning data (796) are not present in 576; if a package ever
// carries them the reader fails instead of guessing.
Shader_Cache :: struct {
	shaders:       int,
	material_maps: int,
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

	if version >= 538 {
		_ = read_u8(&r) // Platform
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
	for _ in 0 ..< int(shaders) {
		r.pos += 8 // FName type
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
		r.pos = int(skip)
	}
	result.material_maps = int(maps)
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.shader-cache-layout", fmt.aprintf("UShaderCache consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
