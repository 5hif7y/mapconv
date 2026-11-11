package ue3

import "core:testing"
import "../diag"

// The material shader map payload is the part of a shader cache that was jumped over
// for months. These tests build one by hand and break it in each of the ways a walker
// can drift, so a failure names the check that caught it.

Shader_Map_Fixture :: struct {
	data:    [dynamic]u8,
	catalog: map[[16]u8]bool,
	names:   []Name,
	pkg:     Package,
}

shader_map_fixture :: proc() -> Shader_Map_Fixture {
	f: Shader_Map_Fixture
	f.catalog = make(map[[16]u8]bool, 4)
	guid := [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	f.catalog[guid] = true
	// The names have to outlive the call: a composite literal here would hand back a
	// slice into a frame that no longer exists.
	f.names = make([]Name, 3)
	f.names[0].text = "None"
	f.names[1].text = "TBasePassPixelShader"
	f.names[2].text = "FLocalVertexFactory"
	return f
}

shader_map_destroy :: proc(f: ^Shader_Map_Fixture) {
	delete(f.data)
	delete(f.catalog)
	delete(f.names)
}

// put_ref writes one shader reference: the map's key FName, the shader's GUID and the
// type FName the reference repeats.
put_ref :: proc(b: ^[dynamic]u8, key, value: i32, guid: [16]u8) {
	g := guid
	put_i32_buf(b, key)
	put_i32_buf(b, 0)
	append(b, ..g[:])
	put_i32_buf(b, value)
	put_i32_buf(b, 0)
}

put_i32_buf :: proc(b: ^[dynamic]u8, v: i32) {
	u := u32(v)
	append(b, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24))
}

// build_material_map writes a whole FMaterialShaderMap payload: one shader reference,
// no mesh maps, then the material's identity, its name, its parameter set and platform.
build_material_map :: proc(with_shader: bool, null_ref: bool) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, 96)
	guid := [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	put_i32_buf(&out, with_shader ? 1 : 0)
	if with_shader {
		if null_ref {
			put_ref(&out, 1, 0, [16]u8{})
		} else {
			put_ref(&out, 1, 1, guid)
		}
	}
	put_i32_buf(&out, 0) // mesh shader maps
	append(&out, ..guid[:]) // MaterialId
	name := "M_Test\x00"
	put_i32_buf(&out, i32(len(name)))
	append(&out, ..transmute([]u8)name)
	append(&out, ..guid[:]) // BaseMaterialId
	put_i32_buf(&out, 0) // static switches
	put_i32_buf(&out, 0) // component masks
	put_i32_buf(&out, 0) // platform
	return out
}

run_material_map :: proc(f: ^Shader_Map_Fixture, payload: []u8, platform: u8 = 0) -> (Shader_Cache, diag.Diagnostics) {
	f.pkg = Package{data = payload, names = f.names}
	r := Reader{data = payload, pos = 0, limit = len(payload)}
	result: Shader_Cache
	d := diag.init()
	_ = material_shader_map(&f.pkg, &r, len(payload), f.catalog, platform, &result, &d)
	return result, d
}

@(test)
test_a_material_shader_map_walk_covers_its_payload :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(true, false)
	defer delete(payload)
	result, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, !diag.has_errors(&d), "a well formed map must walk")
	testing.expect_value(t, result.shader_refs, 1)
	testing.expect_value(t, result.null_refs, 0)
	testing.expect_value(t, result.material_bytes, len(payload))
	testing.expect_value(t, result.id_mismatch, 0)
}

@(test)
test_a_reference_to_a_shader_the_cache_lacks_fails :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(true, false)
	defer delete(payload)
	// The GUID at offset 12 belongs to no shader of the cache.
	payload[12] = 0x77
	_, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	if len(d.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d.items[0].code, "ue3.material-map-guid")
	}
}

@(test)
test_a_reference_whose_type_differs_from_its_record_fails :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(true, false)
	defer delete(payload)
	// The repeated type at offset 28 becomes another name than the key.
	payload[28] = 2
	_, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	if len(d.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d.items[0].code, "ue3.material-map-type")
	}
}

@(test)
test_a_null_reference_names_none :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(true, true)
	defer delete(payload)
	result, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, !diag.has_errors(&d), "a zero GUID with None is how the writer stores a shader it lacks")
	testing.expect_value(t, result.null_refs, 1)

	// The same zero GUID with a real type is not a null reference: it would name a
	// shader that cannot exist.
	broken := build_material_map(true, true)
	defer delete(broken)
	broken[28] = 1
	_, d2 := run_material_map(&f, broken[:])
	defer delete(d2.items)
	testing.expect(t, diag.has_errors(&d2))
	if len(d2.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d2.items[0].code, "ue3.material-map-null")
	}
}

@(test)
test_a_material_name_must_be_terminated :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(false, false)
	defer delete(payload)
	// The friendly name is "M_Test\0": drop the terminator.
	payload[28 + 6] = 'x'
	_, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	if len(d.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d.items[0].code, "ue3.material-map-name")
	}
}

@(test)
test_a_payload_with_bytes_left_over_fails :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(false, false)
	defer delete(payload)
	append(&payload, 0x00)
	_, d := run_material_map(&f, payload[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	if len(d.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d.items[0].code, "ue3.material-map-layout")
	}
}

@(test)
test_a_map_must_name_its_cache_platform :: proc(t: ^testing.T) {
	f := shader_map_fixture()
	defer shader_map_destroy(&f)
	payload := build_material_map(false, false)
	defer delete(payload)
	_, d := run_material_map(&f, payload[:], 1)
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	if len(d.items) == 0 {
		testing.expect(t, false, "the walker reported no reason")
	} else {
		testing.expect_value(t, d.items[0].code, "ue3.material-map-platform")
	}
}
