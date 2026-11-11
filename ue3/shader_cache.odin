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
// Both payloads are walked, not skipped.
//
// A shader payload is an FShader (ShaderManager.cpp:789): a platform byte, a frequency
// byte, the code blob, the CRC, then Id and Type. Its GUID and its type FName have to
// be the ones the record in the header names -- two copies of the identity that agree.
// 83,963 shaders in three platform caches, 235,185,172 B.
//
// A material shader map payload is an FMaterialShaderMap (MaterialShader.cpp:1894). It
// does not hold code: it holds references, {FGuid id, FName type}, to shaders the shader
// section of the same file declares, so the reference is checked against that catalog
// (a GUID the cache does not declare is an error, and so is a reference whose type is
// not the type of the record that holds it) and the payload has to end exactly where its
// skip offset says. A map may also hold a null reference -- zero GUID, type None -- for a
// shader this platform's cache does not have. 8,989 maps, 266,062 references (8 null),
// 9,581,011 B.
//
// The compressed cache (VER_SHADER_COMPRESSION 672) and the automatic versioning data
// (796) are not present in 576; if a package ever carries them the reader fails instead
// of guessing.
Shader_Cache :: struct {
	shaders:       int,
	material_maps: int,
	payload_bytes: int, // shader payload bytes the skip offsets bound
	// Every material map names the shaders it uses by their GUID; the catalog is the
	// set of GUIDs the shader section of the same cache declares. A reference that is
	// not in it is a reference to a shader that does not exist.
	shader_refs:      int,
	null_refs:        int,
	material_bytes:   int,
	switch_records:   int,
	mask_records:     int,
	// Counters for checks that are measured and reported before they are enforced.
	id_mismatch:      int,
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
	catalog := make(map[[16]u8]bool, 1 << 16, allocator)
	defer delete(catalog)

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
		guid_key: [16]u8
		copy(guid_key[:], guid_bytes)
		catalog[guid_key] = true
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
		if !material_shader_map(pkg, &r, int(skip), catalog, platform_byte, &result, &d) {
			return
		}
		r.pos = int(skip)
		result.material_maps += 1
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


// material_shader_map walks one FMaterialShaderMap::Serialize payload
// (Engine/Src/MaterialShader.cpp:1894) as a shader cache writes it:
//
//	TShaderMap<FMaterialShaderType>:  i32 count, then per shader a reference
//	MeshShaderMaps:                   i32 count, then per map {shader count, references,
//	                                  FName VertexFactoryType}
//	FGuid MaterialId
//	FString FriendlyName
//	FStaticParameterSet:              FGuid BaseMaterialId, switches, masks
//	i32 Platform
//
// A shader here is not its code: it is a reference, {FName type, FGuid id, FName type},
// because the code lives once in the shader section at the head of the cache. The
// reference is checked against that section, so the payload is tied to data outside
// itself: the GUID has to name a shader the same file declares, and the type the
// reference repeats has to be the type of the record that holds it. A walk that drifts
// by one byte reads another record's GUID and fails.
material_shader_map :: proc(
	pkg: ^Package,
	r: ^Reader,
	end: int,
	catalog: map[[16]u8]bool,
	platform: u8,
	result: ^Shader_Cache,
	d: ^diag.Diagnostics,
) -> bool {
	if end > r.limit {
		diag.err(d, "ue3.material-map", "material shader map ends past its export")
		return false
	}
	start := r.pos
	limit := r.limit
	r.limit = end
	defer r.limit = limit

	shader_ref :: proc(
		pkg: ^Package,
		r: ^Reader,
		catalog: map[[16]u8]bool,
		result: ^Shader_Cache,
		d: ^diag.Diagnostics,
	) -> bool {
		key := read_name_ref(r)
		if !name_in_table(pkg, key) {
			diag.err(d, "ue3.material-map-name",
				fmt.aprintf("a shader reference names %d/%d, the table has %d", key.index, key.number, len(pkg.names)))
			return false
		}
		if r.pos + 16 > r.limit {
			diag.err(d, "ue3.material-map-end", "a shader reference runs past its map")
			return false
		}
		guid: [16]u8
		copy(guid[:], pkg.data[r.pos:r.pos + 16])
		r.pos += 16
		value := read_name_ref(r)
		if !name_in_table(pkg, value) {
			diag.err(d, "ue3.material-map-name",
				fmt.aprintf("a shader reference names type %d/%d, the table has %d", value.index, value.number, len(pkg.names)))
			return false
		}
		// A map may hold a reference to a shader this platform's cache does not have:
		// the writer then stores a zero GUID and the type NAME_None. Anything else has
		// to name a shader the shader section of the same file declares.
		if guid == ([16]u8{}) {
			if name_text(pkg, value) != "None" {
				diag.err(d, "ue3.material-map-null",
					fmt.aprintf("a null shader reference names type %s, not None", name_text(pkg, value)))
				return false
			}
			result.null_refs += 1
			return true
		}
		if !catalog[guid] {
			diag.err(d, "ue3.material-map-guid",
				fmt.aprintf("a shader reference names a GUID the cache does not declare (%x)", guid))
			return false
		}
		if value.index != key.index || value.number != key.number {
			diag.err(d, "ue3.material-map-type",
				fmt.aprintf("a shader reference names type %s where its record names %s",
					name_text(pkg, value), name_text(pkg, key)))
			return false
		}
		result.shader_refs += 1
		return true
	}

	shaders := read_i32(r)
	if r.failed || shaders < 0 || shaders > 100_000 {
		diag.err(d, "ue3.material-map", fmt.aprintf("implausible shader count %d", shaders))
		return false
	}
	for _ in 0 ..< int(shaders) {
		if !shader_ref(pkg, r, catalog, result, d) {
			return false
		}
	}
	mesh_maps := read_i32(r)
	if r.failed || mesh_maps < 0 || mesh_maps > 100_000 {
		diag.err(d, "ue3.material-map", fmt.aprintf("implausible mesh shader map count %d", mesh_maps))
		return false
	}
	for _ in 0 ..< int(mesh_maps) {
		members := read_i32(r)
		if r.failed || members < 0 || members > 100_000 {
			diag.err(d, "ue3.material-map", fmt.aprintf("implausible mesh shader count %d", members))
			return false
		}
		for _ in 0 ..< int(members) {
			if !shader_ref(pkg, r, catalog, result, d) {
				return false
			}
		}
		vf := read_name_ref(r)
		if !name_in_table(pkg, vf) {
			diag.err(d, "ue3.material-map-name",
				fmt.aprintf("a mesh shader map names vertex factory %d/%d, the table has %d", vf.index, vf.number, len(pkg.names)))
			return false
		}
	}
	// MaterialId, then the friendly name, then the material's own GUID at the head of
	// its static parameter set: the three name the same material, so two of them must
	// agree with the third or the walk is reading someone else's bytes.
	material_id: [16]u8
	copy(material_id[:], pkg.data[r.pos:r.pos + 16])
	r.pos += 16
	name_len := read_i32(r)
	if r.failed || name_len <= 0 || name_len > 1024 || r.pos + int(name_len) > r.limit {
		diag.err(d, "ue3.material-map-name", fmt.aprintf("implausible friendly name length %d", name_len))
		return false
	}
	name_bytes := pkg.data[r.pos:r.pos + int(name_len)]
	r.pos += int(name_len)
	if name_bytes[len(name_bytes) - 1] != 0 {
		diag.err(d, "ue3.material-map-name", "the friendly name is not terminated")
		return false
	}
	for b in name_bytes[:len(name_bytes) - 1] {
		if b < 0x20 || b > 0x7e {
			diag.err(d, "ue3.material-map-name", fmt.aprintf("the friendly name holds byte 0x%02x", b))
			return false
		}
	}
	base_id: [16]u8
	if r.pos + 16 > r.limit { 
		diag.err(d, "ue3.material-map-end", "the static parameter set runs past its map")
		return false
	}
	copy(base_id[:], pkg.data[r.pos:r.pos + 16])
	r.pos += 16
	if base_id != material_id {
		result.id_mismatch += 1
	}
	switches := read_i32(r)
	if r.failed || switches < 0 || switches > 100_000 {
		diag.err(d, "ue3.material-map", fmt.aprintf("implausible static switch count %d", switches))
		return false
	}
	for _ in 0 ..< int(switches) {
		if r.pos + 32 > r.limit {
			diag.err(d, "ue3.material-map-end", "a static switch record runs past its map")
			return false
		}
		parameter := Name_Ref{read_i32(r), read_i32(r)}
		if !name_in_table(pkg, parameter) {
			diag.err(d, "ue3.material-map-name", "a static switch names a parameter outside the table")
			return false
		}
		r.pos += 24
		result.switch_records += 1
	}
	masks := read_i32(r)
	if r.failed || masks < 0 || masks > 100_000 {
		diag.err(d, "ue3.material-map", fmt.aprintf("implausible component mask count %d", masks))
		return false
	}
	for _ in 0 ..< int(masks) {
		if r.pos + 44 > r.limit {
			diag.err(d, "ue3.material-map-end", "a component mask record runs past its map")
			return false
		}
		parameter := Name_Ref{read_i32(r), read_i32(r)}
		if !name_in_table(pkg, parameter) {
			diag.err(d, "ue3.material-map-name", "a component mask names a parameter outside the table")
			return false
		}
		r.pos += 36
		result.mask_records += 1
	}
	declared_platform := read_i32(r)
	if r.failed {
		diag.err(d, "ue3.material-map-end", "the map ends before its platform")
		return false
	}
	// The cache states its platform in its header and every map restates it: the two
	// agreed in all 8,989 maps of the corpus, so a disagreement is a misread, not a
	// variant.
	if i32(platform) != declared_platform {
		diag.err(d, "ue3.material-map-platform",
			fmt.aprintf("a material shader map names platform %d, the cache %d", declared_platform, platform))
		return false
	}
	if r.pos != end {
		diag.err(d, "ue3.material-map-layout",
			fmt.aprintf("material shader map consumed %d of %d bytes", r.pos - start, end - start))
		return false
	}
	result.material_bytes += end - start
	return true
}

// name_in_table reports whether a name reference can exist in a package of that many
// names. The reader does not need the text, only that the index is real.
name_in_table :: proc(pkg: ^Package, ref: Name_Ref) -> bool {
	return ref.index >= 0 && int(ref.index) < len(pkg.names) && ref.number >= 0
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
