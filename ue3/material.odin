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
	defer delete(head_d.items)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
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
