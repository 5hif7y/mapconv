// Material audit: what a map needs and what it carries.
//
// A Source map names one material per texdata record, and the archive in lump 40
// carries the VMT and VTF of the materials the map packs for itself. The rest live
// in the game's VPK, outside the file. Reporting the split is the first step of a
// conversion that has to end with the surfaces textured: it says how much of a map
// travels with the file and how much has to be resolved from the game.
package bsp

import "core:fmt"
import "core:strings"
import "../diag"

Mat_Report :: struct {
	named:        int, // material names the map refers to
	in_pakfile:   int, // of those, how many have their VMT inside lump 40
	with_texture: int, // of those, how many also carry the VTF the VMT asks for
	packed:       int, // entries in the archive in total
	in_vpk:       int, // of the missing, how many the game VPK does hold
	nowhere:      int, // of the missing, how many no VPK has
	missing:      []string, // names with no VMT in the archive (owned by the caller)
}

material_report_destroy :: proc(report: ^Mat_Report) {
	for name in report.missing {
		delete(name)
	}
	delete(report.missing)
	report.missing = nil
}

// report_materials compares the materials the map names with the ones the archive
// carries. Every name is probed as materials/<lowercased name>.vmt, which is where
// a Source material for texture T lives.
report_materials :: proc(data: []u8, file: ^File, map_name: string, allocator := context.allocator) -> (report: Mat_Report) {
	offset, length := file.header[LUMP_PAKFILE][0], file.header[LUMP_PAKFILE][1]
	entries, d := read_pakfile(data, offset, length)
	defer {
		for entry in entries {
			delete(entry.name)
		}
		delete(entries)
		delete(d.items)
	}
	report.packed = len(entries)
	index := make(map[string]int, len(entries), allocator)
	defer {
		for key in index {
			delete(key)
		}
		delete(index)
	}
	for entry, i in entries {
		index[strings.to_lower(entry.name, allocator)] = i
	}

	missing := make([dynamic]string, 0, 16, allocator)
	seen := make(map[string]bool, len(file.texdata), allocator)
	defer {
		for key in seen {
			delete(key)
		}
		delete(seen)
	}
	for info in file.texinfo {
		if info.texdata < 0 || info.texdata >= len(file.texdata) {
			continue
		}
		name := file.texdata[info.texdata].name
		if name == "" {
			continue
		}
		lower := strings.to_lower(name, allocator)
		if lower in seen {
			delete(lower)
			continue
		}
		seen[lower] = true
		report.named += 1
		// The compiler moves a material the map uses into the map's own folder, so
		// both the plain path and materials/maps/<map>/... have to be probed.
		plain := fmt.aprintf("materials/%s.vmt", lower, allocator = context.temp_allocator)
		maped := fmt.aprintf("materials/maps/%s/%s.vmt", strings.to_lower(map_name, context.temp_allocator), lower, allocator = context.temp_allocator)
		slot, packed := index[plain]
		if !packed {
			slot, packed = index[maped]
		}
		if !packed {
			append(&missing, strings.clone(lower, allocator))
			continue
		}
		report.in_pakfile += 1
		payload, ok := pak_entry_data(data, entries[slot])
		if !ok {
			continue
		}
		defer if entries[slot].method == 8 {
			delete(payload)
		}
		base, has_base := basetexture_of(string(payload))
		if !has_base {
			continue
		}
		base_lower := strings.to_lower(base, context.temp_allocator)
		vtf := fmt.aprintf("materials/%s.vtf", base_lower, allocator = context.temp_allocator)
		vtf_maped := fmt.aprintf("materials/maps/%s/%s.vtf", strings.to_lower(map_name, context.temp_allocator), base_lower, allocator = context.temp_allocator)
		if vtf in index || vtf_maped in index {
			report.with_texture += 1
		}
	}
	report.missing = missing[:]
	return
}

// basetexture_of returns the value of $basetexture in a VMT, which is the name of
// the VTF that has to travel with it.
basetexture_of :: proc(text: string) -> (name: string, ok: bool) {
	return vmt_value(text, "\"$basetexture\"")
}

// tooltexture_of returns the texture the engine shows for a material outside the
// renderer. A Water shader has no albedo at all -- it refracts -- and names only
// "%tooltexture", so that is the closest thing to a surface a conversion can carry.
tooltexture_of :: proc(text: string) -> (name: string, ok: bool) {
	return vmt_value(text, "\"%tooltexture\"")
}

// vmt_value returns the value that follows a quoted key in a VMT.
vmt_value :: proc(text: string, key: string) -> (value: string, ok: bool) {
	lower := strings.to_lower(text, context.temp_allocator)
	at := strings.index(lower, key)
	if at < 0 {
		return "", false
	}
	rest := text[at + len(key):]
	open := strings.index(rest, "\"")
	if open < 0 {
		return "", false
	}
	rest = rest[open + 1:]
	close_at := strings.index(rest, "\"")
	if close_at < 0 {
		return "", false
	}
	return rest[:close_at], true
}

// include_of returns the material a "patch" VMT builds on. A patch does not name a
// texture of its own: it includes another material and replaces some of its keys,
// which is how the compiler writes the per-instance variants it bakes into a map.
include_of :: proc(text: string) -> (path: string, ok: bool) {
	lower := strings.to_lower(text, context.temp_allocator)
	key := "\"include\""
	at := strings.index(lower, key)
	if at < 0 {
		return "", false
	}
	rest := text[at + len(key):]
	open := strings.index(rest, "\"")
	if open < 0 {
		return "", false
	}
	rest = rest[open + 1:]
	close_at := strings.index(rest, "\"")
	if close_at < 0 {
		return "", false
	}
	return rest[:close_at], true
}

// material_report_text renders the split for inspect and extract.
material_report_text :: proc(report: Mat_Report) -> string {
	if report.in_vpk > 0 || report.nowhere > 0 {
		if report.nowhere > 0 && len(report.missing) > 0 {
			names := strings.builder_make(0, 128)
			for name, i in report.missing {
				if i == 4 {
					strings.write_string(&names, " …")
					break
				}
				if i > 0 {
					strings.write_string(&names, ", ")
				}
				strings.write_string(&names, name)
			}
			return fmt.aprintf(
				"materials: %d named · %d in the pakfile (%d with the VTF too) · %d outside: %d in the game VPK, %d nowhere (%s)",
				report.named, report.in_pakfile, report.with_texture,
				report.named - report.in_pakfile, report.in_vpk, report.nowhere,
				strings.to_string(names),
			)
		}
		return fmt.aprintf(
			"materials: %d named · %d in the pakfile (%d with the VTF too) · %d outside: %d in the game VPK, %d nowhere",
			report.named, report.in_pakfile, report.with_texture,
			report.named - report.in_pakfile, report.in_vpk, report.nowhere,
		)
	}
	return fmt.aprintf(
		"materials: %d named · %d with a VMT in the pakfile · %d of those with the VTF too · %d to resolve from the game VPK",
		report.named, report.in_pakfile, report.with_texture,
		report.named - report.in_pakfile,
	)
}

// materials_of reads the map and reports its materials, for the callers that hold
// the file bytes and not a parsed map.
materials_of :: proc(data: []u8, map_name: string, allocator := context.allocator) -> (report: Mat_Report, ok: bool) {
	d := diag.init()
	defer delete(d.items)
	file, err := read(data, &d, "")
	if err != .None {
		return {}, false
	}
	return report_materials(data, &file, map_name, allocator), true
}
