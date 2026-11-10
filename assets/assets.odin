// Texture resolution: from the name a surface carries to the pixels it shows.
//
// A Source map names one material per texture record. The material is a VMT in the
// map's own pakfile (lump 40) or in the game's VPK; the VMT names a VTF; the VTF
// holds the mip chain the surface samples. This package walks that chain and writes
// the largest mip as DDS, so a converter can hand over textures instead of names.
//
// Three forms the archives actually contain, each of them found by a failing map:
//
//   - a "patch" VMT has no $basetexture: it includes another material and replaces
//     keys, which is how the compiler bakes per-instance variants into a map;
//   - a VMT may write its path with backslashes (glass\blinds_illuminated);
//   - a per-instance name carries a suffix (…_wvt_patch, …_<x>_<y>_<z>) that the
//     material it came from does not have.
package assets

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../bsp"
import "../diag"
import "../vpk"
import "../vtf"

// Result is what one map's texture export produced. `have` is keyed by the
// lowercased material name the map uses, so a caller can ask which faces end up
// textured without probing the disk again.
Result :: struct {
	converted:     int, // materials written as DDS
	missing:       int, // materials with no texture in any archive
	missing_names: [dynamic]string, // of those, the names (owned by the result)
	have:          map[string]bool, // material -> a DDS was written
	bytes:         int, // total size of the DDS written
}

destroy :: proc(result: ^Result) {
	for name in result.missing_names {
		delete(name)
	}
	delete(result.missing_names)
	result.missing_names = nil
	for key in result.have {
		delete(key)
	}
	delete(result.have)
	result.have = nil
}

// export writes <output>/textures/<material>.dds for every material the map refers
// to, resolving from the map's archive first and from the given VPK trees after.
export :: proc(data: []u8, map_name, output: string, trees: []vpk.Tree, allocator := context.allocator) -> (result: Result, ok: bool) {
	d := diag.init()
	defer delete(d.items)
	file, err := bsp.read(data, &d, "")
	if err != .None {
		return result, false
	}
	offset, length := file.header[bsp.LUMP_PAKFILE][0], file.header[bsp.LUMP_PAKFILE][1]
	entries, pak_d := bsp.read_pakfile(data, offset, length)
	defer {
		for entry in entries {
			delete(entry.name)
		}
		delete(entries)
		delete(pak_d.items)
	}
	pak_index := make(map[string]int, len(entries), allocator)
	defer {
		for key in pak_index {
			delete(key)
		}
		delete(pak_index)
	}
	for entry, i in entries {
		pak_index[strings.to_lower(entry.name, allocator)] = i
	}
	lower_map := strings.to_lower(map_name, context.temp_allocator)

	result.have = make(map[string]bool, 256, allocator)
	seen := make(map[string]bool, 256, context.temp_allocator)
	defer delete(seen)
	for info in file.texinfo {
		if info.texdata < 0 || info.texdata >= len(file.texdata) {
			continue
		}
		raw := file.texdata[info.texdata].name
		if raw == "" || raw in seen {
			continue
		}
		seen[raw] = true
		name := strings.to_lower(raw, allocator)
		texture, texture_ok := material_texture(data, entries, pak_index, trees, lower_map, name)
		if !texture_ok {
			result.missing += 1
			append(&result.missing_names, strings.clone(name, allocator))
			continue
		}
		wrote := write_texture(output, name, texture)
		result.bytes += len(texture)
		delete(texture)
		if wrote {
			result.converted += 1
			result.have[name] = true
		} else {
			result.missing += 1
			append(&result.missing_names, strings.clone(name, allocator))
		}
	}
	// The importer marks a brush side with no texinfo as TOOLS/TOOLSNODRAW, so that
	// name has to travel even when no texture record of the map mentions it: a
	// polygon whose material has no file is the one thing a converted brush must not
	// carry.
	nodraw := NODRAW_MATERIAL
	if !result.have[nodraw] {
		texture, texture_ok := material_texture(data, entries, pak_index, trees, lower_map, nodraw)
		if texture_ok {
			if write_texture(output, nodraw, texture) {
				result.converted += 1
				result.bytes += len(texture)
				result.have[strings.clone(nodraw, allocator)] = true
			}
			delete(texture)
		}
	}
	return result, true
}

// NODRAW_MATERIAL is the material the importer gives a brush side that is not drawn.
NODRAW_MATERIAL :: "tools/toolsnodraw"

// material_texture resolves one material name to the bytes of its largest mip as
// DDS. It returns nothing when no archive holds the chain.
material_texture :: proc(data: []u8, entries: []bsp.Pak_Entry, index: map[string]int, trees: []vpk.Tree, map_name, name: string) -> (dds: []u8, ok: bool) {
	vmt, vmt_ok := asset(data, entries, index, trees, fmt.aprintf("materials/%s.vmt", name, allocator = context.temp_allocator))
	if !vmt_ok {
		// The compiler moves the materials a map uses into the map's own folder.
		vmt, vmt_ok = asset(data, entries, index, trees, fmt.aprintf("materials/maps/%s/%s.vmt", map_name, name, allocator = context.temp_allocator))
	}
	if !vmt_ok {
		if stripped, changed := strip_variant_suffix(name); changed {
			vmt, vmt_ok = asset(data, entries, index, trees, fmt.aprintf("materials/%s.vmt", stripped, allocator = context.temp_allocator))
			if !vmt_ok {
				vmt, vmt_ok = asset(data, entries, index, trees, fmt.aprintf("materials/maps/%s/%s.vmt", map_name, stripped, allocator = context.temp_allocator))
			}
		}
	}
	if !vmt_ok {
		return nil, false
	}

	base, has_base := bsp.basetexture_of(string(vmt))
	// A patch includes another material instead of naming a texture; follow the
	// include chain. The buffer is only released once a replacement has been read:
	// freeing it first and then breaking out of the loop frees it twice.
	if !has_base {
		for _ in 0 ..< 4 {
			include, has_include := bsp.include_of(string(vmt))
			if !has_include {
				break
			}
			next := strings.to_lower(include, context.temp_allocator)
			next_path := strings.has_prefix(next, "materials/") ? next : fmt.aprintf("materials/%s", next, allocator = context.temp_allocator)
			replacement, replacement_ok := asset(data, entries, index, trees, next_path)
			if !replacement_ok {
				break
			}
			delete(vmt)
			vmt = replacement
			base, has_base = bsp.basetexture_of(string(vmt))
			if has_base {
				break
			}
		}
	}
	if !has_base {
		// A Water shader refracts instead of drawing a surface, so it has no
		// $basetexture; "%tooltexture" is the texture the engine itself shows for it.
		base, has_base = bsp.tooltexture_of(string(vmt))
	}
	// A VMT may write the path with backslashes, which Source accepts.
	base_lower := has_base ? strings.to_lower(forward_slashes(base), context.temp_allocator) : ""
	delete(vmt)
	if !has_base {
		return nil, false
	}

	texture, texture_ok := asset(data, entries, index, trees, fmt.aprintf("materials/%s.vtf", base_lower, allocator = context.temp_allocator))
	if !texture_ok {
		texture, texture_ok = asset(data, entries, index, trees, fmt.aprintf("materials/maps/%s/%s.vtf", map_name, base_lower, allocator = context.temp_allocator))
	}
	if !texture_ok {
		// A per-instance patch borrows the texture of the material it patches.
		if stripped, changed := strip_variant_suffix(base_lower); changed {
			texture, texture_ok = asset(data, entries, index, trees, fmt.aprintf("materials/%s.vtf", stripped, allocator = context.temp_allocator))
		}
	}
	if !texture_ok {
		return nil, false
	}
	conversion := diag.init()
	bytes, _, bytes_ok := vtf.to_dds(texture, &conversion)
	delete(conversion.items)
	delete(texture)
	if !bytes_ok {
		return nil, false
	}
	return bytes, true
}

// asset returns a fresh buffer for a path, from the map's archive or any VPK.
asset :: proc(data: []u8, entries: []bsp.Pak_Entry, index: map[string]int, trees: []vpk.Tree, path: string) -> (payload: []u8, ok: bool) {
	if slot, packed := index[path]; packed {
		bytes, entry_ok := bsp.pak_entry_data(data, entries[slot])
		if !entry_ok {
			return nil, false
		}
		if entries[slot].method == 8 {
			return bytes, true
		}
		return clone(bytes), true
	}
	for &tree in trees {
		entry, _, found := vpk.lookup(&tree, path)
		if !found {
			continue
		}
		bytes, read_ok, read_d := vpk.read_entry(&tree, entry)
		delete(read_d.items)
		if read_ok {
			return bytes, true
		}
	}
	return nil, false
}

write_texture :: proc(output, name: string, dds: []u8) -> bool {
	path := fmt.aprintf("%s/textures/%s.dds", output, name, allocator = context.temp_allocator)
	// A material name carries a folder ("de_dust/groundsand03"), so the tree has to
	// be created under textures/ before the file is written.
	_ = os.make_directory_all(filepath.dir(path))
	return os.write_entire_file(path, dds) == nil
}

clone :: proc(bytes: []u8) -> []u8 {
	out := make([]u8, len(bytes))
	copy(out, bytes)
	return out
}

// forward_slashes turns the backslashes a VMT may use into path separators.
forward_slashes :: proc(path: string) -> string {
	if !strings.contains_rune(path, '\\') {
		return path
	}
	out := make([]u8, len(path), context.temp_allocator)
	for c, i in transmute([]u8)path {
		out[i] = c == '\\' ? '/' : c
	}
	return string(out)
}

// strip_variant_suffix removes the suffix the compiler appends to a per-instance
// material: "_wvt_patch" for a blend patch and "_<x>_<y>_<z>" for a static prop
// patch. What is left names the material the surface was built from.
strip_variant_suffix :: proc(name: string) -> (base: string, changed: bool) {
	if strings.has_suffix(name, "_wvt_patch") {
		return name[:len(name) - len("_wvt_patch")], true
	}
	position := len(name)
	for _ in 0 ..< 3 {
		if position <= 0 || name[position - 1] < '0' || name[position - 1] > '9' {
			return name, false
		}
		for position > 0 && name[position - 1] >= '0' && name[position - 1] <= '9' {
			position -= 1
		}
		// A coordinate is signed: a patch is named after the point it was baked at,
		// and half of them are negative.
		if position > 0 && name[position - 1] == '-' {
			position -= 1
		}
		if position == 0 || name[position - 1] != '_' {
			return name, false
		}
		position -= 1
	}
	if position == 0 || position == len(name) {
		return name, false
	}
	return name[:position], true
}

// Report renders the summary line for a corpus or a single map.
report_text :: proc(result: ^Result) -> string {
	if len(result.missing_names) == 0 {
		return fmt.aprintf("textures: %d of %d material(s) converted to DDS (%d bytes)",
			result.converted, result.converted + result.missing, result.bytes)
	}
	names := strings.builder_make(0, 128)
	for name, i in result.missing_names {
		if i == 4 {
			strings.write_string(&names, " …")
			break
		}
		if i > 0 {
			strings.write_string(&names, ", ")
		}
		strings.write_string(&names, name)
	}
	return fmt.aprintf("textures: %d of %d material(s) converted to DDS, %d without one (%s)",
		result.converted, result.converted + result.missing, result.missing, strings.to_string(names))
}
