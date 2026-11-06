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
				info.texture_name = name
				info.has_texture = true
				break
			}
		}
		if info.has_texture {
			break
		}
	}
	return
}

material_vmt :: proc(info: Material_Texture) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "\"VertexLitGeneric\"\n{\n")
	fmt.sbprintf(&b, "\t\"$basetexture\" \"%s\"\n", info.texture_name)
	strings.write_string(&b, "\t\"$model\" \"1\"\n}\n")
	return strings.to_string(b)
}
