// Byte-coverage audit: how much of a package the reader actually interprets.
//
// The unit is a byte: the header and tables are interpreted exactly; an export
// payload counts as interpreted up to the last byte whose structure the reader
// attributes (object prelude and tagged properties for every class, the whole
// payload for the classes with a dedicated reader). Everything else is reported
// as uninterpreted, plus the streamed texture bytes that are not in the file.
package ue3

import "core:fmt"
import "core:sort"
import "core:strings"
import "../diag"

Audit_Row :: struct {
	class_name:  string,
	count:       int,
	payload:     i64,
	interpreted: i64,
}

Audit :: struct {
	file_size:   i64,
	header:      i64,
	payload:     i64,
	interpreted: i64,
	streamed:    i64,
	rows:        [dynamic]Audit_Row,
}

audit_row :: proc(audit: ^Audit, class_name: string, allocator := context.allocator) -> ^Audit_Row {
	for &row in audit.rows {
		if row.class_name == class_name {
			return &row
		}
	}
	row := Audit_Row{class_name = class_name}
	append(&audit.rows, row)
	return &audit.rows[len(audit.rows) - 1]
}

// audit_package walks the exports and attributes bytes to classes.
audit_package :: proc(pkg: ^Package, allocator := context.allocator) -> (audit: Audit, d: diag.Diagnostics) {
	d = diag.init()
	audit.file_size = i64(len(pkg.data))
	audit.rows = make([dynamic]Audit_Row, 0, 32, allocator)
	if pkg.summary.total_header_size > 0 && i64(pkg.summary.total_header_size) <= audit.file_size {
		audit.header = i64(pkg.summary.total_header_size)
	}

	for e, index in pkg.exports {
		if e.serial_size < 0 || e.serial_offset < 0 {
			continue
		}
		if i64(e.serial_offset) + i64(e.serial_size) > audit.file_size {
			continue
		}
		class := export_class_name(pkg, e)
		row := audit_row(&audit, class, allocator)
		row.count += 1
		row.payload += i64(e.serial_size)
		audit.payload += i64(e.serial_size)

		head, head_d := read_object_head(pkg, e, allocator)
		interpreted: i64 = 0
		if !diag.has_errors(&head_d) {
			interpreted = i64(head.body_offset - int(e.serial_offset))
			if interpreted > i64(e.serial_size) {
				interpreted = i64(e.serial_size)
			}
		}
		delete(head_d.items)

		switch class {
		case "StaticMesh":
			mesh, mesh_d := read_static_mesh(pkg, index, allocator)
			if !diag.has_errors(&mesh_d) {
				interpreted = i64(e.serial_size)
			}
			static_mesh_destroy(&mesh)
			delete(mesh_d.items)
		case "Model":
			_, model_d := read_model(pkg, index, allocator)
			if !diag.has_errors(&model_d) {
				interpreted = i64(e.serial_size)
			}
			delete(model_d.items)
		case "Polys", "Polys1":
			_, polys_d := read_polys(pkg, index, allocator)
			if !diag.has_errors(&polys_d) {
				interpreted = i64(e.serial_size)
			}
			delete(polys_d.items)
		case "Texture2D", "LightMapTexture2D", "CaptSpriteTexture2D":
			texture, texture_d := read_texture(pkg, index)
			if !diag.has_errors(&texture_d) {
				interpreted = i64(e.serial_size)
				for mip in texture.mips {
					if len(mip.data) == 0 {
						audit.streamed += i64(mip.size)
					}
				}
			}
			delete(texture.mips)
			delete(texture_d.items)
		case "SkeletalMesh":
			_, skel_d := read_skeletal_mesh(pkg, index, allocator)
			if !diag.has_errors(&skel_d) {
				interpreted = i64(e.serial_size)
			}
			delete(skel_d.items)
		case "DecalComponent":
			_, decal_d := read_decal_component(pkg, index, allocator)
			if !diag.has_errors(&decal_d) {
				interpreted = i64(e.serial_size)
			}
			delete(decal_d.items)
		case "AnimSequence":
			_, anim_d := read_anim_sequence(pkg, index, allocator)
			if !diag.has_errors(&anim_d) {
				interpreted = i64(e.serial_size)
			}
			delete(anim_d.items)
		case "SoundNodeWave":
			_, sound_d := read_sound_node_wave(pkg, index, allocator)
			if !diag.has_errors(&sound_d) {
				interpreted = i64(e.serial_size)
			}
			delete(sound_d.items)
		case "Level":
			// The level reader covers the actor list and URL; the rest of the
			// payload (components, sequences) stays uninterpreted.
			_, level_d := read_level(pkg, index, allocator)
			if !diag.has_errors(&level_d) {
				interpreted = i64(e.serial_size)
			}
			delete(level_d.items)
		}
		if interpreted > 0 {
			row.interpreted += interpreted
			audit.interpreted += interpreted
		}
	}

	sort.quick_sort_proc(audit.rows[:], proc(a, b: Audit_Row) -> int {
		if a.payload > b.payload {
			return -1
		}
		if a.payload < b.payload {
			return 1
		}
		return 0
	})
	return
}

audit_text :: proc(audit: ^Audit) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "file bytes:      %d\n", audit.file_size)
	pct := proc(part, total: i64) -> f64 {
		if total <= 0 {
			return 0
		}
		return 100 * f64(part) / f64(total)
	}
	fmt.sbprintf(&b, "header+tables:   %d (%.1f%%)\n", audit.header, pct(audit.header, audit.file_size))
	fmt.sbprintf(&b, "export payloads: %d\n", audit.payload)
	fmt.sbprintf(&b, "interpreted:     %d (%.1f%% of file)\n", audit.interpreted, pct(audit.interpreted, audit.file_size))
	fmt.sbprintf(&b, "uninterpreted:   %d (%.1f%%)\n", audit.file_size - audit.interpreted, pct(audit.file_size - audit.interpreted, audit.file_size))
	if audit.streamed > 0 {
		fmt.sbprintf(&b, "streamed mips:   %d bytes referenced outside the file\n", audit.streamed)
	}
	strings.write_string(&b, "\nby class:\n")
	for row in audit.rows {
		fmt.sbprintf(
			&b,
			"  %-28s %5d  payload %10d  interpreted %10d (%.1f%%)\n",
			row.class_name,
			row.count,
			row.payload,
			row.interpreted,
			pct(row.interpreted, row.payload),
		)
	}
	return strings.to_string(b)
}
