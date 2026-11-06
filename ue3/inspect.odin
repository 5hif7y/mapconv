// Human-readable package inspection, used by `mapconv inspect` and `validate`.
package ue3

import "core:fmt"
import "core:sort"
import "core:strings"
import "../diag"

// inspect_text summarizes a parsed package: enough to tell whether the file was
// read correctly and what the object graph will look like in the next stage.
inspect_text :: proc(pkg: ^Package, path: string) -> string {
	s := &pkg.summary
	b := strings.builder_make()

	fmt.sbprintf(&b, "package:      %s\n", path)
	fmt.sbprintf(&b, "tag:          0x%08X\n", s.tag)
	fmt.sbprintf(
		&b,
		"versions:     package %d (licensee %d), engine build %d, cooked content %d\n",
		engine_version(s),
		licensee_version(s),
		s.engine_build,
		s.cooked_content_version,
	)
	fmt.sbprintf(&b, "header:       %d bytes, folder %q\n", s.total_header_size, s.folder_name)
	fmt.sbprintf(&b, "flags:        0x%08X (%s)\n", s.package_flags, package_flags_text(s.package_flags))
	fmt.sbprintf(&b, "guid:         %s\n", guid_string(s.guid))

	fmt.sbprintf(&b, "generations:  %d", len(s.generations))
	if len(s.generations) > 0 {
		strings.write_string(&b, " (")
		for g, i in s.generations {
			if i > 0 {
				strings.write_string(&b, "; ")
			}
			fmt.sbprintf(&b, "exports %d, names %d, net objects %d", g.export_count, g.name_count, g.net_object_count)
		}
		strings.write_string(&b, ")")
	}
	strings.write_byte(&b, '\n')

	fmt.sbprintf(&b, "compression:  %s", compression_flags_text(s.compression_flags))
	if len(s.compressed_chunks) > 0 {
		fmt.sbprintf(&b, ", %d chunk(s)", len(s.compressed_chunks))
	}
	else {
		strings.write_string(&b, ", no chunks")
	}
	strings.write_byte(&b, '\n')

	if len(s.additional_packages_to_cook) > 0 {
		fmt.sbprintf(&b, "cook stack:   %s\n", strings.join(s.additional_packages_to_cook, ", "))
	}

	fmt.sbprintf(
		&b,
		"tables:       names %d @%d, imports %d @%d, exports %d @%d, depends @%d\n",
		s.name_count,
		s.name_offset,
		s.import_count,
		s.import_offset,
		s.export_count,
		s.export_offset,
		s.depends_offset,
	)

	// Top-level objects (outer index null) grouped by class: these are the
	// packages' roots and show whether the map's Level/Model/Brush chain is there.
	class_counts := make(map[string]int, 16)
	defer delete(class_counts)
	top_level := 0
	for e in pkg.exports {
		if e.outer_index != 0 {
			continue
		}
		top_level += 1
		class_counts[export_class_name(pkg, e)] += 1
	}
	classes := make([dynamic]string, 0, len(class_counts))
	defer delete(classes)
	for name in class_counts {
		append(&classes, name)
	}
	plain := classes[:]
	sort.sort(sort.slice_interface(&plain))

	// Brush volumes carry their authoring geometry as UPolys objects: parse them
	// all so the summary states how much brush data the package actually holds.
	polys_objects := 0
	polygons := 0
	vertices := 0
	polys_errors := 0
	for e, i in pkg.exports {
		if export_class_name(pkg, e) != "Polys" {
			continue
		}
		polys_objects += 1
		set, set_diags := read_polys(pkg, i)
		defer delete(set_diags.items)
		if diag.has_errors(&set_diags) {
			polys_errors += 1
			continue
		}
		polygons += len(set.polygons)
		vertices += set.vertices
	}

	fmt.sbprintf(&b, "top-level:    %d object(s) with no outer, %d distinct class(es)\n", top_level, len(class_counts))
	shown := 0
	for name in plain {
		if shown == 30 {
			fmt.sbprintf(&b, "  ... %d more class(es)\n", len(plain) - shown)
			break
		}
		fmt.sbprintf(&b, "  %-40s %d\n", name, class_counts[name])
		shown += 1
	}

	// BSP models hold the level's visible geometry; parse them so the summary
	// states how much is available (conversion of these polygons is pending).
	models := 0
	model_nodes := 0
	model_surfs := 0
	model_verts := 0
	model_poly_count := 0
	model_solid_count := 0
	model_errors := 0
	for e, i in pkg.exports {
		if export_class_name(pkg, e) != "Model" {
			continue
		}
		models += 1
		m, m_diags := read_model(pkg, i)
		defer delete(m_diags.items)
		if diag.has_errors(&m_diags) {
			model_errors += 1
			continue
		}
		model_nodes += len(m.nodes)
		model_surfs += len(m.surfs)
		model_verts += len(m.verts)
		polys := model_polygons(&m)
		model_poly_count += len(polys)
		if outer_is_level(pkg, e) {
			solids := model_solids(&m)
			model_solid_count += len(solids)
		}
	}

	if polys_objects > 0 {
		fmt.sbprintf(
			&b,
			"brush polys:  %d UPolys object(s), %d polygon(s), %d vertex/vertices",
			polys_objects,
			polygons,
			vertices,
		)
		if polys_errors > 0 {
			fmt.sbprintf(&b, ", %d object(s) failed to parse", polys_errors)
		}
		strings.write_byte(&b, '\n')
	}

	// Level actors: the native body stores the actor references and the URL.
	level_actors := 0
	level_label := ""
	actor_classes := make(map[string]int, 16)
	defer delete(actor_classes)
	for e, i in pkg.exports {
		if export_class_name(pkg, e) != "Level" {
			continue
		}
		lvl, lvl_diags := read_level(pkg, i)
		defer delete(lvl_diags.items)
		if diag.has_errors(&lvl_diags) {
			continue
		}
		level_label = name_text(pkg, e.object_name)
		level_actors += len(lvl.actors)
		for actor in lvl.actors {
			class := actor_class_name(pkg, actor)
			if class != "" {
				actor_classes[class] += 1
			}
		}
	}

	if models > 0 {
		fmt.sbprintf(
			&b,
			"bsp models:   %d model(s), %d node(s), %d surface(s), %d vert(s), %d polygon(s)",
			models,
			model_nodes,
			model_surfs,
			model_verts,
			model_poly_count,
		)
		if model_solid_count > 0 {
			fmt.sbprintf(&b, ", %d solid region(s)", model_solid_count)
		}
		if model_errors > 0 {
			fmt.sbprintf(&b, ", %d model(s) failed to parse", model_errors)
		}
		strings.write_byte(&b, '\n')
	}

	if level_actors > 0 {
		fmt.sbprintf(&b, "level:        %s, %d actor(s)", level_label, level_actors)
		// Print up to six classes, most frequent first.
		actor_names := make([dynamic]string, 0, len(actor_classes))
		defer delete(actor_names)
		for name in actor_classes {
			append(&actor_names, name)
		}
		actor_plain := actor_names[:]
		sort.sort(sort.slice_interface(&actor_plain))
		order := make([]string, len(actor_plain))
		defer delete(order)
		copy(order, actor_plain)
		for i in 0..<len(order) {
			for j in i + 1..<len(order) {
				if actor_classes[order[j]] > actor_classes[order[i]] {
					order[i], order[j] = order[j], order[i]
				}
			}
		}
		actor_shown := 0
		for name in order {
			if actor_shown == 6 {
				break
			}
			if actor_shown == 0 {
				fmt.sbprintf(&b, ": ")
			} else {
				fmt.sbprintf(&b, ", ")
			}
			fmt.sbprintf(&b, "%s %d", name, actor_classes[name])
			actor_shown += 1
		}
		if len(order) > 6 {
			fmt.sbprintf(&b, ", +%d more", len(order) - 6)
		}
		strings.write_byte(&b, '\n')
	}

	return strings.to_string(b)
}
