// UE3 material textures.
//
// Cooked materials carry ReferencedTextures, an array of FPackageIndex:
// INT count followed by count references. It is what the renderer samples and
// the only thing a VMT needs ($basetexture).
package ue3

import "core:fmt"
import "core:strings"
import "../diag"

Material_Texture :: struct {
	material_name: string,
	texture_name:  string,
	has_texture:   bool,
	bump_name:     string,
	has_bump:      bool,
}

read_material_texture :: proc(pkg: ^Package, export_index: int, allocator := context.allocator) -> (info: Material_Texture, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		return
	}
	e := pkg.exports[export_index]
	info.material_name = name_text(pkg, e.object_name)
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller: deleting them here and
		// again in the caller is a double free that kills the process.
		d = head_d
		return
	}
	defer delete(head_d.items)
	for tag in head.tags {
		if tag_name(pkg, tag) != "ReferencedTextures" || tag.size < 4 {
			continue
		}
		r := Reader{data = pkg.data, pos = tag.value_offset, limit = tag.value_offset + int(tag.size)}
		count := read_i32(&r)
		if r.failed || count <= 0 || count > 4096 {
			continue
		}
		for _ in 0..<int(count) {
			value := read_i32(&r)
			if r.failed {
				break
			}
			name := package_index_name(pkg, value)
			if name != "" && name != "None" {
				// The first reference is not necessarily the diffuse: UE3 lists
				// normal maps among them. A normal map used as $basetexture is
				// what produced the purple/striped surfaces in the engine.
				if looks_like_normal(name) {
					if !info.has_bump {
						info.bump_name = name
						info.has_bump = true
					}
				} else if looks_like_mask(name) {
					// Channel masks (floor_mask) render as flat RGB if used as
					// the diffuse; leave the base empty for the fallback.
					continue
				} else if !info.has_texture {
					info.texture_name = name
					info.has_texture = true
				}
			}
		}
		if info.has_texture {
			break
		}
	}
	return
}

// is_diffuse_candidate reports whether a texture name may serve as $basetexture.
is_diffuse_candidate :: proc(name: string) -> bool {
	return !looks_like_normal(name) && !looks_like_mask(name)
}

looks_like_mask :: proc(name: string) -> bool {
	lower := strings.to_lower(name)
	// Channel-blend maps (3_blend_dirt_map) are literal red/green/blue bands and
	// rendered as bright RGB panels when sampled as the diffuse.
	if strings.contains(lower, "blend_dirt") || strings.contains(lower, "blend_map") || strings.contains(lower, "channel_map") {
		return true
	}
	return strings.contains(lower, "mask") || strings.has_suffix(lower, "_lm")
}

looks_like_normal :: proc(name: string) -> bool {
	lower := strings.to_lower(name)
	normal_suffixes := [11]string{"_n", "_nm", "_norm", "_normal", "_bump", "_bumpmap", "_normalmap", "_nrm", "_nsp", "_ns", "_spec"}
	for suffix in normal_suffixes {
		if strings.has_suffix(lower, suffix) {
			return true
		}
	}
	if strings.contains(lower, "normal") || strings.contains(lower, "bumpmap") {
		return true
	}
	return strings.has_prefix(lower, "n_")
}

// UE3 blend modes have no direct byte in the cooked material we read, so the
// shader is chosen from the material name and the sampled texture: effects
// (light beams, fire, smoke, dust) are additive or translucent in the source
// game and render as flat RGB panels under VertexLitGeneric.
material_shader :: proc(mat_name, texture_name: string) -> (shader: string, params: string) {
	// Source model shaders: UnlitGeneric refuses the studiomdl vertex format
	// ("does not support vertex format used by the mesh"), so every material
	// stays VertexLitGeneric and emissive textures are self-lit instead.
	lower := strings.to_lower(mat_name)
	texture_lower := strings.to_lower(texture_name)
	emissive := strings.has_suffix(texture_lower, "_e") || strings.contains(texture_lower, "emissive") || strings.contains(texture_lower, "neon")
	b := strings.builder_make()
	strings.write_string(&b, "\t\"$model\" \"1\"\n")
	if emissive {
		strings.write_string(&b, "\t\"$selfillum\" \"1\"\n\t\"$selfillumtint\" \"[1 1 1]\"\n")
	}
	if strings.contains(lower, "smoke") || strings.contains(lower, "dust") {
		strings.write_string(&b, "\t\"$translucent\" \"1\"\n")
	}
	return "VertexLitGeneric", strings.to_string(b)
}

material_vmt_for :: proc(mat_name: string, info: Material_Texture) -> string {
	b := strings.builder_make()
	shader, params := material_shader(mat_name, info.texture_name)
	// Concatenation, not fmt: a literal "{" in a format string is a delimiter
	// and silently disappears, which leaves an invalid VMT.
	strings.write_string(&b, "\"")
	strings.write_string(&b, shader)
	strings.write_string(&b, "\"\n{\n")
	fmt.sbprintf(&b, "\t\"$basetexture\" \"%s\"\n", info.texture_name)
	if info.has_bump && shader == "VertexLitGeneric" {
		fmt.sbprintf(&b, "\t\"$bumpmap\" \"%s\"\n", info.bump_name)
	}
	strings.write_string(&b, params)
	strings.write_string(&b, "}\n")
	if shader != "VertexLitGeneric" {
		delete(params)
	}
	return strings.to_string(b)
}

material_vmt :: proc(info: Material_Texture) -> string {
	return material_vmt_for(info.material_name, info)
}

// FMaterial::Serialize (Engine/Src/MaterialShared.cpp:1949) for 576: the
// payload repeats one FMaterialResource block per saved quality level (the
// measured exports carry two identical-sized blocks). Each block stores the
// compile errors, the texture dependency map, the material GUID, the legacy
// uniform expression arrays (the shader cache took them over at 656) and the
// texture lookup table.
Material_Body :: struct {
	blocks:          int,
	expressions:     int,
	texture_lookups: int,
}

// skip_expression walks one FMaterialUniformExpression given its type name.
// Composed expressions (FoldedMath, AppendVector) recurse on their operands.
skip_expression :: proc(r: ^Reader, pkg: ^Package, type_name: string) -> bool {
	params: int
	switch type_name {
	case "FMaterialUniformExpressionTime", "FMaterialUniformExpressionRealTime":
		params = 0
	case "FMaterialUniformExpressionTexture":
		params = 4
	case "FMaterialUniformExpressionTextureParameter",
	     "FMaterialUniformExpressionFlipBookTextureParameter":
		// The flip book variant adds nothing to the texture parameter layout.
		params = 12
	case "FMaterialUniformExpressionScalarParameter":
		params = 12
	case "FMaterialUniformExpressionVectorParameter":
		params = 24
	case "FMaterialUniformExpressionConstant":
		// FLinearColor (16) plus the BYTE ValueType
		params = 17
	case "FMaterialUniformExpressionPeriodic", "FMaterialUniformExpressionSquareRoot",
	     "FMaterialUniformExpressionLength", "FMaterialUniformExpressionFloor",
	     "FMaterialUniformExpressionCeil", "FMaterialUniformExpressionFrac",
	     "FMaterialUniformExpressionAbs", "FMaterialUniformExpressionSign",
	     "FMaterialUniformExpressionOneMinus", "FMaterialUniformExpressionSaturate":
		// one nested expression
		return skip_uniform_array_element(r, pkg)
	case "FMaterialUniformExpressionTransformRange":
		// Vogster's addition: A, InputLeftVal, InputRightVal, OutputLeftVal and
		// OutputRightVal, five nested expressions in that order
		// (Engine/Src/MaterialShared.cpp:3822).
		for _ in 0 ..< 5 {
			if !skip_uniform_array_element(r, pkg) {
				return false
			}
		}
		return true
	case "FMaterialUniformExpressionClamp":
		// Input, Min and Max
		if !skip_uniform_array_element(r, pkg) || !skip_uniform_array_element(r, pkg) || !skip_uniform_array_element(r, pkg) {
			return false
		}
		return true
	case "FMaterialUniformExpressionMin", "FMaterialUniformExpressionMax":
		// A and B
		return skip_uniform_array_element(r, pkg) && skip_uniform_array_element(r, pkg)
	case "FMaterialUniformExpressionAppendVector", "FMaterialUniformExpressionFoldedMath":
		// A, B, then the operator (BYTE) or the component count (INT)
		if !skip_uniform_array_element(r, pkg) || !skip_uniform_array_element(r, pkg) {
			return false
		}
		extra := 1
		if type_name == "FMaterialUniformExpressionAppendVector" {
			extra = 4
		}
		if r.limit - r.pos < extra {
			return false
		}
		r.pos += extra
		return true
	case "FMaterialUniformExpressionSine":
		// X plus the UBOOL bIsCosine
		if !skip_uniform_array_element(r, pkg) {
			return false
		}
		if r.limit - r.pos < 4 {
			return false
		}
		r.pos += 4
		return true
	case:
		reader_fail(r, fmt.aprintf("unknown uniform expression type %s", type_name))
		return false
	}
	if i64(params) > i64(r.limit - r.pos) {
		return false
	}
	r.pos += params
	return true
}

// skip_uniform_array_element reads one element: its type name then parameters.
skip_uniform_array_element :: proc(r: ^Reader, pkg: ^Package) -> bool {
	type_name := name_text(pkg, read_name_ref(r))
	if r.failed {
		return false
	}
	return skip_expression(r, pkg, type_name)
}

// skip_uniform_array walks one legacy expression array. Each element is an
// FName type followed by that type's parameters (MaterialShared.cpp:1104).
skip_uniform_array :: proc(r: ^Reader, pkg: ^Package, result: ^Material_Body) -> bool {
	count := read_i32(r)
	if r.failed || count < 0 || count > 100_000 {
		return false
	}
	result.expressions += int(count)
	for _ in 0 ..< int(count) {
		if !skip_uniform_array_element(r, pkg) {
			return false
		}
	}
	return true
}

// parse_material_resource consumes one FMaterialResource block.
parse_material_resource :: proc(r: ^Reader, pkg: ^Package, version: i32, result: ^Material_Body) -> bool {
	errors := read_i32(r)
	if r.failed || errors < 0 || errors > 100_000 {
		return false
	}
	for _ in 0 ..< int(errors) {
		_ = read_fstring(r)
		if r.failed {
			return false
		}
	}
	deps := read_i32(r)
	if r.failed || deps < 0 || deps > 1_000_000 || i64(deps) * 8 > i64(r.limit - r.pos) {
		return false
	}
	r.pos += int(deps) * 8
	if r.limit - r.pos < 24 {
		return false
	}
	r.pos += 4  // MaxTextureDependencyLength
	r.pos += 16 // Id (FGuid)
	r.pos += 4  // NumUserTexCoords

	if !skip_uniform_array(r, pkg, result) ||
	   !skip_uniform_array(r, pkg, result) ||
	   !skip_uniform_array(r, pkg, result) ||
	   !skip_uniform_array(r, pkg, result) {
		return false
	}
	if r.limit - r.pos < 16 {
		return false
	}
	r.pos += 4 // bUsesSceneColor
	r.pos += 4 // bUsesSceneDepth
	if version >= 558 {
		r.pos += 4 // bUsesDynamicParameter
	}
	r.pos += 4 // UsingTransforms
	lookups := read_i32(r)
	if r.failed || lookups < 0 || lookups > 1_000_000 {
		return false
	}
	stride := 16
	if version < 506 {
		stride = 12
	}
	if i64(lookups) * i64(stride) + 4 > i64(r.limit - r.pos) {
		return false
	}
	r.pos += int(lookups) * stride
	result.texture_lookups += int(lookups)
	r.pos += 4 // DummyDroppedFallbackComponents
	return true
}

read_material_body :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Material_Body, d: diag.Diagnostics) {
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
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	for r.pos < head.end_offset {
		if !parse_material_resource(&r, pkg, version, &result) {
			diag.err(&d, "ue3.bad-material", fmt.aprintf("material resource did not parse at %d (%s)", r.pos, r.message))
			return
		}
		result.blocks += 1
		if result.blocks > 8 {
			diag.err(&d, "ue3.bad-material", "too many resource blocks")
			return
		}
	}
	return
}

// FStaticParameterSet::Serialize (MaterialShared.h:1773): a GUID, the static
// switch array (FName + two UBOOLs + FGuid = 32 B) and the component mask array
// (FName + five UBOOLs + FGuid = 44 B). The normal and terrain layer arrays are
// gated at 631/714 and are absent in 576.
skip_static_parameter_set :: proc(r: ^Reader, version: i32) -> bool {
	if r.limit - r.pos < 16 {
		return false
	}
	r.pos += 16 // BaseMaterialId
	switches := read_i32(r)
	if r.failed || switches < 0 || switches > 100_000 {
		return false
	}
	if i64(switches) * 32 > i64(r.limit - r.pos) {
		return false
	}
	r.pos += int(switches) * 32
	masks := read_i32(r)
	if r.failed || masks < 0 || masks > 100_000 {
		return false
	}
	if i64(masks) * 44 > i64(r.limit - r.pos) {
		return false
	}
	r.pos += int(masks) * 44
	return true
}

// UMaterialInstance::Serialize (MaterialInstance.cpp:1527): when the instance
// has a static permutation resource the body holds one material resource block
// per saved quality plus its static parameter set, and before
// VER_REMOVED_SHADER_MODEL_2 (711) a second legacy SM2 pair.
Material_Instance :: struct {
	blocks: int,
}

read_material_instance :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Material_Instance, d: diag.Diagnostics) {
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
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}

	has_resource := false
	if tag, ok := find_tag(pkg, head.tags, "bHasStaticPermutationResource"); ok {
		has_resource = tag.bool_value != 0
	}
	if has_resource {
		material: Material_Body
		if !parse_material_resource(&r, pkg, version, &material) {
			diag.err(&d, "ue3.bad-material-instance", "static permutation resource did not parse")
			return
		}
		if !skip_static_parameter_set(&r, version) {
			diag.err(&d, "ue3.bad-material-instance", "static parameter set did not parse")
			return
		}
		result.blocks += 1
		if version < 711 {
			if !parse_material_resource(&r, pkg, version, &material) {
				diag.err(&d, "ue3.bad-material-instance", "legacy SM2 resource did not parse")
				return
			}
			if !skip_static_parameter_set(&r, version) {
				diag.err(&d, "ue3.bad-material-instance", "legacy SM2 parameter set did not parse")
				return
			}
			result.blocks += 1
		}
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.material-instance-layout", fmt.aprintf("UMaterialInstance consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
