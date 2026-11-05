// IR -> VMF.
package vmf

import "core:fmt"
import "core:strconv"
import "core:strings"
import "../diag"
import "../geom"
import "../ir"

// ExportOptions controls serializer behaviour that has a visible effect on the
// output text but not on the represented geometry.
ExportOptions :: struct {
	// write_editor_blocks emits a Hammer-style `editor` block for solids without
	// a preserved one. Disable for diff-oriented output.
	write_editor_blocks: bool,
	// preserved_extensions re-emits blocks the importer kept verbatim.
	preserved_extensions: bool,
}

DEFAULT_EXPORT_OPTIONS :: ExportOptions {
	write_editor_blocks = true,
	preserved_extensions = true,
}

Id_Allocator :: struct {
	next: int,
	used: map[string]bool,
}

alloc_id :: proc(a: ^Id_Allocator, source_id: string) -> string {
	if source_id != "" {
		if v, ok := strconv.parse_int(source_id); ok && v > 0 && !a.used[source_id] {
			a.used[source_id] = true
			if v >= a.next {
				a.next = v + 1
			}
			return source_id
		}
	}
	for {
		s := fmt.aprintf("%d", a.next)
		a.next += 1
		if !a.used[s] {
			a.used[s] = true
			return s
		}
	}
}

Writer :: struct {
	b:    strings.Builder,
	ids:  Id_Allocator,
	opts: ExportOptions,
	// skipped_foreign counts surface attributes that belong to another format's
	// namespace and cannot be expressed in VMF.
	skipped_foreign: int,
}

write_line :: proc(w: ^Writer, indent: int, text: string) {
	for _ in 0 ..< indent {
		strings.write_byte(&w.b, '\t')
	}
	strings.write_string(&w.b, text)
	strings.write_string(&w.b, "\n")
}

write_kv :: proc(w: ^Writer, indent: int, key, value: string) {
	write_line(w, indent, ir.concat("\"", escape(key), "\" \"", escape(value), "\""))
}

write_open :: proc(w: ^Writer, indent: int, name: string) {
	write_line(w, indent, name)
	write_line(w, indent, "{")
}

write_close :: proc(w: ^Writer, indent: int) {
	write_line(w, indent, "}")
}

export_document :: proc(d: ^ir.Document, dg: ^diag.Diagnostics, opts := DEFAULT_EXPORT_OPTIONS) -> string {
	w := Writer {
		opts = opts,
	}
	w.ids = Id_Allocator {
		next = 1,
		used = make(map[string]bool, 64),
	}
	strings.builder_init(&w.b)

	write_line(&w, 0, "versioninfo")
	write_line(&w, 0, "{")
	write_kv(&w, 1, "editorversion", "400")
	write_kv(&w, 1, "editorbuild", "mapconv")
	write_kv(&w, 1, "mapversion", "1")
	write_kv(&w, 1, "formatversion", "100")
	write_kv(&w, 1, "prefab", "0")
	write_close(&w, 0)
	write_line(&w, 0, "visgroups")
	write_line(&w, 0, "{")
	write_close(&w, 0)

	write_world(&w, d, dg)
	for &entity in d.entities {
		if entity.class_name == "worldspawn" {
			diag.warn(dg, "vmf.second-worldspawn", "a second worldspawn entity is exported as a regular entity", entity.id)
		}
		write_entity(&w, &entity, d, dg)
	}

	if opts.preserved_extensions {
		for ext in d.extensions {
			if strings.has_prefix(ext.name, "vmf.block:") {
				write_verbatim(&w, 0, ext.data)
			}
		}
	}
	if w.skipped_foreign > 0 {
		diag.info(
			dg,
			"vmf.foreign-surface-data",
			fmt.aprintf("%d source-format surface attribute(s) have no VMF equivalent and were dropped", w.skipped_foreign),
		)
	}
	return strings.to_string(w.b)
}

write_world :: proc(w: ^Writer, d: ^ir.Document, dg: ^diag.Diagnostics) {
	write_open(w, 0, "world")
	write_kv(w, 1, "id", alloc_id(&w.ids, d.world.id))
	write_kv(w, 1, "classname", "worldspawn")
	write_entity_props(w, 1, &d.world, dg)
	for brush_index in d.world.brushes {
		if brush_index < 0 || brush_index >= len(d.brushes) {
			diag.warn(dg, "vmf.dangling-brush", "world references a brush that does not exist", fmt.aprintf("%d", brush_index))
			continue
		}
		write_solid(w, 1, &d.brushes[brush_index], dg)
	}
	write_extensions(w, 1, d.world.extensions[:], w.opts.preserved_extensions)
	write_close(w, 0)
}

write_entity :: proc(w: ^Writer, e: ^ir.Entity, d: ^ir.Document, dg: ^diag.Diagnostics) {
	write_line(w, 0, "entity")
	write_line(w, 0, "{")
	write_kv(w, 1, "id", alloc_id(&w.ids, e.id))
	write_kv(w, 1, "classname", e.class_name)
	write_entity_props(w, 1, e, dg)
	for brush_index in e.brushes {
		if brush_index < 0 || brush_index >= len(d.brushes) {
			diag.warn(dg, "vmf.dangling-brush", "entity references a brush that does not exist", e.id)
			continue
		}
		write_solid(w, 1, &d.brushes[brush_index], dg)
	}
	write_extensions(w, 1, e.extensions[:], w.opts.preserved_extensions)
	write_close(w, 0)
}

write_entity_props :: proc(w: ^Writer, indent: int, e: ^ir.Entity, dg: ^diag.Diagnostics) {
	if e.origin != geom.VEC3_ZERO || has_key(e.props[:], "origin") {
		write_kv(w, indent, "origin", geom.vec3_string(e.origin))
	}
	if e.angles != geom.VEC3_ZERO || has_key(e.props[:], "angles") {
		write_kv(w, indent, "angles", geom.vec3_string(e.angles))
	}
	for p in e.props {
		if p.key == "origin" || p.key == "angles" || p.key == "classname" || p.key == "id" {
			continue
		}
		write_kv(w, indent, p.key, value_text(p))
	}
}

has_key :: proc(props: []ir.Property, key: string) -> bool {
	_, ok := ir.find_property(props, key)
	return ok
}

value_text :: proc(p: ir.Property) -> string {
	if p.raw != "" {
		return p.raw
	}
	switch v in p.value {
	case string:
		return v
	case f64:
		return geom.f64_string(v)
	case i64:
		return fmt.aprintf("%d", v)
	case bool:
		return v ? "1" : "0"
	case geom.Vec3:
		return geom.vec3_string(v)
	case ir.Rotation:
		return fmt.aprintf("%d %d %d", v.pitch, v.yaw, v.roll)
	case ir.Raw:
		return v.text
	case ir.Struct_Value, ir.Array_Value:
		return ""
	}
	return ""
}

write_solid :: proc(w: ^Writer, indent: int, b: ^ir.Brush, dg: ^diag.Diagnostics) {
	if b.op != .Add {
		diag.warn(
			dg,
			"vmf.csg-op-unsupported",
			ir.concat("VMF cannot express the '", ir.csg_op_name(b.op), "' CSG operation; the brush is written as additive geometry"),
			b.id,
		)
	}
	write_line(w, indent, "solid")
	write_line(w, indent, "{")
	write_kv(w, indent + 1, "id", alloc_id(&w.ids, b.id))
	preserved_editor := false
	for ext in b.extensions {
		if ext.name == "vmf.block:editor" {
			preserved_editor = true
		}
	}
	for &face in b.faces {
		write_side(w, indent + 1, &face, dg)
	}
	if preserved_editor {
		write_extensions(w, indent + 1, b.extensions[:], w.opts.preserved_extensions)
	} else {
		i := indent + 1
		write_line(w, i, "editor")
		write_line(w, i, "{")
		write_kv(w, i + 1, "color", "0 113 213")
		write_kv(w, i + 1, "visgroupshown", "1")
		write_kv(w, i + 1, "visgroupautoshown", "1")
		write_close(w, i)
	}
	write_close(w, indent)
}

write_side :: proc(w: ^Writer, indent: int, f: ^ir.Face, dg: ^diag.Diagnostics) {
	write_line(w, indent, "side")
	write_line(w, indent, "{")
	write_kv(w, indent + 1, "id", alloc_id(&w.ids, ""))
	p0, p1, p2 := plane_output_points(f)
	write_kv(w, indent + 1, "plane", fmt.aprintf("(%s) (%s) (%s)", geom.vec3_string(p0), geom.vec3_string(p1), geom.vec3_string(p2)))
	material := f.material
	if material == "" {
		material = "TOOLS/TOOLSNODRAW"
		diag.warn(dg, "vmf.face-without-material", "face has no material; writing TOOLS/TOOLSNODRAW", "")
	}
	write_kv(w, indent + 1, "material", material)
	write_kv(w, indent + 1, "uaxis", tex_axis_string(f.uv.u, f.uv.u_offset, f.uv.u_scale))
	write_kv(w, indent + 1, "vaxis", tex_axis_string(f.uv.v, f.uv.v_offset, f.uv.v_scale))
	write_kv(w, indent + 1, "rotation", geom.f64_string(f.uv.rotation))
	write_kv(w, indent + 1, "lightmapscale", geom.f64_string(f.lightmap_scale))
	write_kv(w, indent + 1, "smoothing_groups", fmt.aprintf("%d", f.smoothing_groups))
	for p in f.props {
		if is_foreign_key(p.key) {
			w.skipped_foreign += 1
			continue
		}
		key := p.key
		if strings.has_prefix(key, "vmf.") {
			key = key[4:]
		}
		write_kv(w, indent + 1, key, value_text(p))
	}
	write_extensions(w, indent + 1, f.extensions[:], w.opts.preserved_extensions)
	write_close(w, indent)
}

// is_foreign_key reports whether a stored property belongs to another format's
// namespace (Unreal surface data, for instance) and has no VMF spelling.
is_foreign_key :: proc(key: string) -> bool {
	return strings.has_prefix(key, "t3d.") || strings.has_prefix(key, "source_")
}

tex_axis_string :: proc(axis: geom.Vec3, offset, scale: f64) -> string {
	return fmt.aprintf(
		"[%s %s %s %s] %s",
		geom.f64_string(axis.x),
		geom.f64_string(axis.y),
		geom.f64_string(axis.z),
		geom.f64_string(offset),
		geom.f64_string(scale == 0 ? 1 : scale),
	)
}

// plane_output_points returns the three points VMF stores for a face. The format
// wants them in the order that reproduces the outward normal through
// cross(p0 - p1, p2 - p1), which is the reverse of the counter-clockwise
// winding the IR keeps.
plane_output_points :: proc(f: ^ir.Face) -> (p0, p1, p2: geom.Vec3) {
	w := f.winding
	if len(w) >= 3 {
		for i in 0 ..< len(w) {
			for j in i + 1 ..< len(w) {
				for k in j + 1 ..< len(w) {
					a := w[k]
					b := w[j]
					c := w[i]
					if p, ok := geom.plane_from_points(a, b, c); ok {
						if geom.dot(p.normal, f.plane.normal) > 0.999 {
							return a, b, c
						}
					}
				}
			}
		}
	}
	a, b, c := geom.plane_points(f.plane)
	return a, b, c
}

write_extensions :: proc(w: ^Writer, indent: int, exts: []ir.Extension, enabled: bool) {
	if !enabled {
		return
	}
	for ext in exts {
		if strings.has_prefix(ext.name, "vmf.block:") {
			write_verbatim(w, indent, ext.data)
		}
	}
}

// write_verbatim reindents preserved text to the current block depth so nested
// output stays readable and stable.
write_verbatim :: proc(w: ^Writer, indent: int, text: string) {
	lines := strings.split(text, "\n")
	for line in lines {
		trimmed := strings.trim_left(line, " \t")
		if trimmed == "" {
			continue
		}
		write_line(w, indent, trimmed)
	}
}
