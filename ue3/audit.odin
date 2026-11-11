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

Audit_Object :: struct {
	class_name:  string,
	object_name: string,
	size:        i64,
	interpreted: i64,
	offset:      i64,
	reason:      string,
	// detail carries the first diagnostic of the reader that failed, so a
	// residual can be classified from the report instead of a debugger.
	detail:      string,
}

Audit :: struct {
	file_size:   i64,
	header:      i64,
	payload:     i64,
	interpreted: i64,
	streamed:    i64,
	rows:        [dynamic]Audit_Row,
	objects:     [dynamic]Audit_Object,
	// Shader cache totals: the material shader maps and the references they hold, so
	// the audit states what was walked and not only that the bytes were consumed.
	shader_maps:      int,
	shader_refs:      int,
	shader_nulls:     int,
	shader_map_bytes: int,
	shader_id_mismatch:       int,
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
	audit.objects = make([dynamic]Audit_Object, 0, 32, allocator)
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
		detail: string = ""
		row := audit_row(&audit, class, allocator)
		row.count += 1
		row.payload += i64(e.serial_size)
		audit.payload += i64(e.serial_size)

		head, head_d := read_object_head(pkg, e, allocator, index)
		head_failed := diag.has_errors(&head_d)
		interpreted: i64 = 0
		if !head_failed {
			interpreted = i64(head.body_offset - int(e.serial_offset))
			if interpreted > i64(e.serial_size) {
				interpreted = i64(e.serial_size)
			}
		}
		delete(head_d.items)

		// A class export is not an object with tagged properties: its body is the
		// class record. Those exports carry no class reference of their own, which
		// is why the object head cannot read them.
		if head_failed && e.class_index == 0 {
			_, class_d := read_class_body(pkg, index)
			if !diag.has_errors(&class_d) {
				interpreted = i64(e.serial_size)
			} else if len(class_d.items) > 0 && detail == "" {
				detail = class_d.items[0].message
			}
			delete(class_d.items)
		}

		// A component subobject may end with up to sixteen zero bytes after its tag
		// stream. The engine source does not explain them (UComponent::PreSerialize
		// writes its prelude before the tag stream, not after) and they carry no
		// length, so this is an envelope: the bytes are credited only because they
		// are zero and end the payload, and any other tail is reported.
		if !head_failed && head.has_subobject && !strings.has_prefix(class, "UIComp_") {
			if tail := head.end_offset - head.body_offset; tail > 0 && tail <= 16 {
				zero := true
				for i in head.body_offset ..< head.end_offset {
					if pkg.data[i] != 0 {
						zero = false
						break
					}
				}
				if zero {
					interpreted = i64(e.serial_size)
				}
			}
		}

		// UI component templates serialize the component prelude (template owner
		// class plus net index) even though their class name does not end in
		// "Component". The prelude and the tag stream are credited byte by byte.
		if strings.has_prefix(class, "UIComp_") {
			// A template of a UI component may or may not carry the prelude, and a
			// class default object never does. Both readings are tried and the one
			// that explains more bytes wins; the tag stream bounds each of them.
			best: i64 = interpreted
			if ui_head, ui_d := read_object_head_ex(pkg, e, allocator, true); !diag.has_errors(&ui_d) {
				if value := i64(ui_head.body_offset - int(e.serial_offset)); value > best {
					best = value
				}
				delete(ui_d.items)
			} else {
				delete(ui_d.items)
			}
			if plain_head, plain_d := read_object_head_ex(pkg, e, allocator, false, true); !diag.has_errors(&plain_d) {
				if value := i64(plain_head.body_offset - int(e.serial_offset)); value > best {
					best = value
				}
				delete(plain_d.items)
			} else {
				delete(plain_d.items)
			}
			interpreted = best
		} else {
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
		case "Texture2D", "LightMapTexture2D", "CaptSpriteTexture2D", "TextureFlipBook", "TerrainWeightMapTexture":
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
		case "TextureRenderTarget2D", "TextureRenderTargetCube", "TextureRenderTarget":
			rtt_d := read_texture_render_target(pkg, index, allocator)
			if !diag.has_errors(&rtt_d) {
				interpreted = i64(e.serial_size)
			} else if len(rtt_d.items) > 0 && detail == "" {
				detail = rtt_d.items[0].message
			}
			delete(rtt_d.items)
		case "SkeletalMesh":
			_, skel_d := read_skeletal_mesh(pkg, index, allocator)
			if !diag.has_errors(&skel_d) {
				interpreted = i64(e.serial_size)
			} else if len(skel_d.items) > 0 && detail == "" {
				detail = skel_d.items[0].message
			}
			delete(skel_d.items)
		case "IntProperty", "BoolProperty", "FloatProperty", "StrProperty", "NameProperty", "ObjectProperty", "StructProperty", "ArrayProperty", "ByteProperty", "ComponentProperty", "InterfaceProperty", "DelegateProperty", "MapProperty", "ClassProperty":
			_, prop_d := read_property(pkg, index, class, allocator)
			if !diag.has_errors(&prop_d) {
				interpreted = i64(e.serial_size)
			}
			delete(prop_d.items)
		case "Const":
			const_d := read_const(pkg, index, allocator)
			if !diag.has_errors(&const_d) {
				interpreted = i64(e.serial_size)
			}
			delete(const_d.items)
		case "Enum":
			enum_d := read_enum(pkg, index, allocator)
			if !diag.has_errors(&enum_d) {
				interpreted = i64(e.serial_size)
			}
			delete(enum_d.items)
		case "Function":
			_, fn_d := read_function(pkg, index, allocator)
			if !diag.has_errors(&fn_d) {
				interpreted = i64(e.serial_size)
			}
			delete(fn_d.items)
		case "ScriptStruct":
			_, struct_d := read_script_struct_with_defaults(pkg, index, allocator)
			if !diag.has_errors(&struct_d) {
				interpreted = i64(e.serial_size)
			}
			delete(struct_d.items)
		case "State":
			_, state_d := read_state(pkg, index, allocator)
			if !diag.has_errors(&state_d) {
				interpreted = i64(e.serial_size)
			}
			delete(state_d.items)
			_, struct_d := read_script_struct(pkg, index, allocator)
			if !diag.has_errors(&struct_d) {
				interpreted = i64(e.serial_size)
			}
			delete(struct_d.items)
		case "FracturedStaticMesh":
			_, fractured_d := read_fractured_static_mesh(pkg, index, allocator)
			if !diag.has_errors(&fractured_d) {
				interpreted = i64(e.serial_size)
			} else if len(fractured_d.items) > 0 {
				detail = fractured_d.items[0].message
			}
			delete(fractured_d.items)
		case "UIStyle":
			_, style_d := read_ui_style(pkg, index, allocator)
			if !diag.has_errors(&style_d) {
				interpreted = i64(e.serial_size)
			} else if len(style_d.items) > 0 {
				detail = style_d.items[0].message
			}
			delete(style_d.items)
		case "PrefabInstance", "UIPrefabInstance":
			entries, prefab_d := read_prefab_instance(pkg, index, allocator)
			if !diag.has_errors(&prefab_d) {
				interpreted = i64(e.serial_size)
			} else if len(prefab_d.items) > 0 && detail == "" {
				detail = prefab_d.items[0].message
			}
			_ = entries
			delete(prefab_d.items)
		case "ForceFeedbackWaveform":
			_, wave_d := read_force_feedback_waveform(pkg, index, allocator)
			if !diag.has_errors(&wave_d) {
				interpreted = i64(e.serial_size)
			} else if len(wave_d.items) > 0 && detail == "" {
				detail = wave_d.items[0].message
			}
			delete(wave_d.items)
		case "UISkin":
			_, skin_d := read_ui_skin(pkg, index, allocator)
			if !diag.has_errors(&skin_d) {
				interpreted = i64(e.serial_size)
			} else if len(skin_d.items) > 0 && detail == "" {
				detail = skin_d.items[0].message
			}
			delete(skin_d.items)
		case "UIDynamicFieldProvider":
			field_d := read_ui_dynamic_field_provider(pkg, index, allocator)
			if !diag.has_errors(&field_d) {
				interpreted = i64(e.serial_size)
			} else if len(field_d.items) > 0 && detail == "" {
				detail = field_d.items[0].message
			}
			delete(field_d.items)
		case "ObjectRedirector":
			redir_d := read_object_redirector(pkg, index, allocator)
			if !diag.has_errors(&redir_d) {
				interpreted = i64(e.serial_size)
			} else if len(redir_d.items) > 0 && detail == "" {
				detail = redir_d.items[0].message
			}
			delete(redir_d.items)
		case "SeqAct_Interp":
			interp_d := read_seq_act_interp(pkg, index, allocator)
			if !diag.has_errors(&interp_d) {
				interpreted = i64(e.serial_size)
			} else if len(interp_d.items) > 0 && detail == "" {
				detail = interp_d.items[0].message
			}
			delete(interp_d.items)
		case "GuidCache":
			_, cache_d := read_guid_cache(pkg, index, allocator)
			if !diag.has_errors(&cache_d) {
				interpreted = i64(e.serial_size)
			} else if len(cache_d.items) > 0 && detail == "" {
				detail = cache_d.items[0].message
			}
			delete(cache_d.items)
		case "RB_BodySetup":
			phys, phys_d := read_precached_phys_data(pkg, index)
			if !diag.has_errors(&phys_d) {
				interpreted = i64(e.serial_size)
			} else if len(phys_d.items) > 0 && detail == "" {
				detail = phys_d.items[0].message
			}
			precached_data_destroy(&phys)
			delete(phys_d.items)
		case "ShadowMap1D":
			_, shadow_d := read_shadow_map_1d(pkg, index, allocator)
			if !diag.has_errors(&shadow_d) {
				interpreted = i64(e.serial_size)
			} else if len(shadow_d.items) > 0 {
				detail = shadow_d.items[0].message
			}
			delete(shadow_d.items)
		case "TextureCube":
			cube_offset, cube_d := read_texture_cube(pkg, index, allocator)

			if !diag.has_errors(&cube_d) && cube_offset > 0 {
				interpreted = i64(e.serial_size)
			} else if len(cube_d.items) > 0 {
				detail = cube_d.items[0].message
			}
			delete(cube_d.items)
		case "PointLightComponent", "SpotLightComponent", "DirectionalLightComponent", "SkyLightComponent", "BeastAreaLightComponent", "LightComponent":
			_, light_d := read_light_component_tail(pkg, index, allocator)
			if !diag.has_errors(&light_d) {
				interpreted = i64(e.serial_size)
			} else if len(light_d.items) > 0 {
				detail = light_d.items[0].message
			}
			delete(light_d.items)
		case "Terrain":
			_, terr_d := read_terrain(pkg, index, allocator)
			if !diag.has_errors(&terr_d) {
				interpreted = i64(e.serial_size)
			} else if len(terr_d.items) > 0 && detail == "" {
				detail = terr_d.items[0].message
			}
			delete(terr_d.items)
		case "TerrainComponent":
			terrain, terrain_d := read_terrain_component(pkg, index, allocator)
			if !diag.has_errors(&terrain_d) {
				// The light map block at the end of the export is still open, so
				// only the arrays are credited.
				interpreted = i64(e.serial_size) - i64(terrain.tail_bytes)
			}
			delete(terrain_d.items)
		case "World":
			_, world_d := read_world(pkg, index, allocator)
			if !diag.has_errors(&world_d) {
				interpreted = i64(e.serial_size)
			} else if len(world_d.items) > 0 {
				detail = world_d.items[0].message
			}
			delete(world_d.items)
		case "Font":
			_, font_d := read_font(pkg, index, allocator)
			if !diag.has_errors(&font_d) {
				interpreted = i64(e.serial_size)
			}
			delete(font_d.items)
		case "PersistentCookerData":
			_, pcd_d := read_persistent_cooker_data(pkg, index, allocator)
			if !diag.has_errors(&pcd_d) {
				interpreted = i64(e.serial_size)
			} else if len(pcd_d.items) > 0 && detail == "" {
				detail = pcd_d.items[0].message
			}
			delete(pcd_d.items)
		case "ShaderCache":
			scache, scache_d := read_shader_cache(pkg, index, allocator)
			if !diag.has_errors(&scache_d) {
				interpreted = i64(e.serial_size)
				audit.shader_maps += scache.material_maps
				audit.shader_refs += scache.shader_refs
				audit.shader_nulls += scache.null_refs
				audit.shader_map_bytes += scache.material_bytes
				audit.shader_id_mismatch += scache.id_mismatch
			} else if len(scache_d.items) > 0 && detail == "" {
				detail = scache_d.items[0].message
			}
			delete(scache_d.items)
		case "PhysicsAssetInstance":
			_, pai_d := read_physics_asset_instance(pkg, index, allocator)
			if !diag.has_errors(&pai_d) {
				interpreted = i64(e.serial_size)
			}
			delete(pai_d.items)
		case "SpeedTree":
			_, st_d := read_speed_tree(pkg, index, allocator)
			if !diag.has_errors(&st_d) {
				interpreted = i64(e.serial_size)
			}
			delete(st_d.items)
		case "BrushComponent":
			_, bc_d := read_brush_component(pkg, index, allocator)
			if !diag.has_errors(&bc_d) {
				interpreted = i64(e.serial_size)
			}
			delete(bc_d.items)
		case "SoundCue":
			_, sc_d := read_sound_cue(pkg, index, allocator)
			if !diag.has_errors(&sc_d) {
				interpreted = i64(e.serial_size)
			}
			delete(sc_d.items)
		case "SpeedTreeComponent":
			_, stc_d := read_speed_tree_component(pkg, index, allocator)
			if !diag.has_errors(&stc_d) {
				interpreted = i64(e.serial_size)
			}
			delete(stc_d.items)
		case "MaterialInstanceConstant", "MaterialInstance":
			_, mi_d := read_material_instance(pkg, index, allocator)
			if !diag.has_errors(&mi_d) {
				interpreted = i64(e.serial_size)
			}
			delete(mi_d.items)
		case "Material", "DecalMaterial":
			_, mat_d := read_material_body(pkg, index, allocator)
			if !diag.has_errors(&mat_d) {
				interpreted = i64(e.serial_size)
			} else if len(mat_d.items) > 0 {
				detail = mat_d.items[0].message
			}
			delete(mat_d.items)
		case "ModelComponent":
			_, mc_d := read_model_component(pkg, index, allocator)
			if !diag.has_errors(&mc_d) {
				interpreted = i64(e.serial_size)
			}
			delete(mc_d.items)
		case "StaticMeshComponent":
			_, smc_d := read_static_mesh_component(pkg, index, allocator)
			if !diag.has_errors(&smc_d) {
				interpreted = i64(e.serial_size)
			}
			delete(smc_d.items)
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
		}
		if interpreted > 0 {
			row.interpreted += interpreted
			audit.interpreted += interpreted
		}
		if interpreted < i64(e.serial_size) {
			reason := "no-reader"
			if head_failed {
				reason = "object-head"
			} else if interpreted > 0 {
				reason = "partial"
			}
			append(&audit.objects, Audit_Object {
				class_name = class,
				object_name = name_text(pkg, e.object_name),
				size = i64(e.serial_size),
				interpreted = interpreted,
				offset = i64(e.serial_offset),
				reason = reason,
				detail = detail,
			})
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

// audit_names_text prints the name table with its indices. A structure that names
// something -- a shader type, a material property -- keeps an index into this table,
// so decoding one starts by being able to read the index.
audit_names_text :: proc(pkg: ^Package) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "\nnames (%d):\n", len(pkg.names))
	for name, i in pkg.names {
		fmt.sbprintf(&b, "  %5d %s\n", i, name.text)
	}
	return strings.to_string(b)
}

// audit_dump_text prints the object head of every export: the offsets, the
// tagged properties and the first bytes of the native body. It is the probe for
// layouts that do not match the reader (a truncated texture, a mystery prefix).
audit_dump_text :: proc(pkg: ^Package) -> string {
	b := strings.builder_make()
	for e, index in pkg.exports {
		if e.serial_size <= 0 {
			continue
		}
		head, head_d := read_object_head(pkg, e, context.allocator, index)
		class := export_class_name(pkg, e)
		name := name_text(pkg, e.object_name)
		if diag.has_errors(&head_d) {
			why := ""
			for item in head_d.items {
				why = fmt.aprintf("%s | %s", why, item.message)
			}
			fmt.sbprintf(&b, "EXPORT %d %s %s serial=%d size=%d class_index=%d outer=%d super=%d archetype=%d HEAD-FAILED %s\n", index, class, name, e.serial_offset, e.serial_size, e.class_index, e.outer_index, e.super_index, e.archetype_index, why)
			delete(head_d.items)
			continue
		}
		fmt.sbprintf(
			&b,
			"EXPORT %d %s %s serial=%d size=%d body=%d tags=%d\n",
			index,
			class,
			name,
			e.serial_offset,
			e.serial_size,
			head.body_offset - int(e.serial_offset),
			len(head.tags),
		)
		for tag in head.tags {
			value_offset := tag.value_offset - int(e.serial_offset)
			fmt.sbprintf(
				&b,
				"  TAG %-28s %-24s size=%-6d arr=%-3d value_at=%d\n",
				tag_name(pkg, tag),
				name_text(pkg, tag.type),
				tag.size,
				tag.array_index,
				value_offset,
			)
		}
		n := head.end_offset - head.body_offset
		if n > 0 {
			fmt.sbprintf(&b, "  BODY %d bytes:", n)
			for i in 0 ..< min(n, 48) {
				fmt.sbprintf(&b, " %02x", pkg.data[head.body_offset + i])
			}
			strings.write_byte(&b, '\n')
		}
		delete(head_d.items)
	}
	return strings.to_string(b)
}

// audit_objects_text lists every export with a residual, largest first, with
// the bytes consumed and the class of failure. It is what turns an aggregate
// percentage into a work queue.
audit_objects_text :: proc(audit: ^Audit) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "\nresiduals (bytes, size, read, class, reason, offset, name):\n")
	rows := make([dynamic]Audit_Object, 0, len(audit.objects))
	defer delete(rows)
	for o in audit.objects {
		append(&rows, o)
	}
	sort.quick_sort_proc(rows[:], proc(a, b: Audit_Object) -> int {
		ra := a.size - a.interpreted
		rb := b.size - b.interpreted
		if ra > rb {
			return -1
		}
		if ra < rb {
			return 1
		}
		return 0
	})
	for o in rows {
		fmt.sbprintf(
			&b,
			"  %10d %10d %10d %-28s %-11s %10d %s\n",
			o.size - o.interpreted,
			o.size,
			o.interpreted,
			o.class_name,
			o.reason,
			o.offset,
			o.object_name,
		)
		if len(o.detail) > 0 {
			fmt.sbprintf(&b, "      %s\n", o.detail)
		}
	}
	return strings.to_string(b)
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
	// D2: the header and tables are parsed by ue3.parse, so they are credited
	// too, but always on their own line so the payload figure stays visible.
	credited := audit.interpreted + audit.header
	if credited > audit.file_size {
		credited = audit.file_size
	}
	fmt.sbprintf(&b, "credited:        %d (%.1f%% of file, payload + tables)\n", credited, pct(credited, audit.file_size))
	fmt.sbprintf(&b, "uninterpreted:   %d (%.1f%%)\n", audit.file_size - credited, pct(audit.file_size - credited, audit.file_size))
	if audit.shader_maps > 0 {
		fmt.sbprintf(&b, "shader maps:     %d map(s), %d shader reference(s) (%d null), %d bytes",
			audit.shader_maps, audit.shader_refs, audit.shader_nulls, audit.shader_map_bytes)
		if audit.shader_id_mismatch > 0 {
			fmt.sbprintf(&b, " (%d map(s) whose material id differs from its parameter set)", audit.shader_id_mismatch)
		}
		strings.write_byte(&b, '\n')
	}
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
