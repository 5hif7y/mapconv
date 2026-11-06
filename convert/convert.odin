// Package convert orchestrates format adapters: it imports into the canonical
// IR, applies explicit transformations and mapping profiles, serializes through
// the target adapter and collects diagnostics for everything that was
// approximated, kept opaquely or dropped.
package convert

import "core:fmt"
import "core:math"
import "core:sort"
import "core:strings"
import "../bsp"
import "../diag"
import "../geom"
import "../ir"
import "../profile"
import "../t3d"
import "../ue3"
import "../vmf"
import "../xform"

Options :: struct {
	// from and to are format overrides; Unknown means "detect".
	from:             ir.Format,
	to:               ir.Format,
	profile_name:     string,
	// keep_source_ids tries to keep authored ids in the output.
	keep_source_ids:  bool,
	// report_materials emits one note per material that was preserved by name.
	report_materials: bool,
}

DEFAULT_OPTIONS :: Options {
	keep_source_ids  = true,
	report_materials = true,
}

Result :: struct {
	output:        string,
	doc:           ir.Document,
	diagnostics:   diag.Diagnostics,
	source_format: ir.Format,
	target_format: ir.Format,
	// ok is false only when a hard error prevented producing output.
	ok:            bool,
}

format_from_extension :: proc(path: string) -> ir.Format {
	lower := strings.to_lower(path)
	switch {
	case strings.has_suffix(lower, ".vmf"):
		return .Source_VMF
	case strings.has_suffix(lower, ".bsp"):
		return .Source_BSP
	case strings.has_suffix(lower, ".t3d"):
		return .Unreal_T3D
	case strings.has_suffix(lower, ".ccmap"):
		return .UE3_Package
	case strings.has_suffix(lower, ".map"):
		return .Valve_220
	}
	return .Unknown
}

// detect_format prefers the file extension and falls back to content sniffing so
// that mislabelled files still import (with a note).
detect_format :: proc(path: string, contents: string) -> (format: ir.Format, by_content: bool) {
	by_extension := format_from_extension(path)
	head := contents
	if len(head) > 4096 {
		head = head[:4096]
	}
	if by_extension != .Unknown {
		// A .bsp may still be a Quake or GoldSrc file; the signature decides.
		if by_extension == .Source_BSP {
			if len(contents) >= 4 && contents[:4] == "VBSP" {
				return .Source_BSP, false
			}
			return .Unknown, false
		}
		if by_extension == .UE3_Package {
			// Package tag 0x9E2A83C1, little-endian: C1 83 2A 9E.
			if has_package_tag(contents) {
				return .UE3_Package, false
			}
			return .Unknown, false
		}
		return by_extension, false
	}
	lower := strings.to_lower(head)
	// Content sniffing only runs when the extension says nothing.
	if has_package_tag(contents) {
		return .UE3_Package, true
	}
	if strings.contains(lower, "begin map") {
		return .Unreal_T3D, true
	}
	if strings.contains(lower, "versioninfo") && strings.contains(lower, "world") {
		return .Source_VMF, true
	}
	return .Unknown, false
}

// has_package_tag reports whether the contents start with the UE3 package magic
// (0x9E2A83C1) in little-endian order.
has_package_tag :: proc(contents: string) -> bool {
	if len(contents) < 4 {
		return false
	}
	return contents[0] == 0xC1 && contents[1] == 0x83 && contents[2] == 0x2A && contents[3] == 0x9E
}

SUPPORTED_FORMATS :: []ir.Format{ir.Format.Source_VMF, ir.Format.Source_BSP, ir.Format.Unreal_T3D}

is_supported :: proc(f: ir.Format) -> bool {
	return f == .Source_VMF || f == .Source_BSP || f == .Unreal_T3D || f == .UE3_Package
}

// Compiled formats are import-only: mapconv does not contain a BSP compiler.
is_target_supported :: proc(f: ir.Format) -> bool {
	return f == .Source_VMF || f == .Unreal_T3D
}

// Engine groups formats that share an authoring model, so their entity classes and
// properties cross over without mapping.
Engine :: enum {
	Unknown,
	Source,
	Unreal,
}

engine_of :: proc(f: ir.Format) -> Engine {
	switch f {
	case .Source_VMF, .Source_BSP, .Goldsrc_MAP, .Valve_220:
		return .Source
	case .Unreal_T3D, .UE3_Package:
		return .Unreal
	case .Unknown:
		return .Unknown
	}
	return .Unknown
}

// import_only runs the importer for a single format without any target, used by
// `inspect` and `validate` (which must also work for import-only formats).
import_only :: proc(data: []u8, source_path: string, opts: Options) -> (ir.Document, diag.Diagnostics) {
	contents := string(data)
	format := opts.from
	d := diag.init()
	if format == .Unknown {
		detected, _ := detect_format(source_path, contents)
		format = detected
	}
	#partial switch format {
	case .Source_VMF:
		return vmf.import_document(contents, source_path)
	case .Source_BSP:
		return bsp.import_document(data, source_path)
	case .Unreal_T3D:
		return t3d.import_document(contents, source_path)
	case .UE3_Package:
		return ue3.import_document(data, source_path)
	case:
		diag.err(&d, "convert.unsupported-source", ir.concat("no importer for format ", ir.format_name(format)), source_path)
		doc := ir.init_document(.Unknown, xform.source_1())
		return doc, d
	}
}

convert_text :: proc(contents, source_path: string, opts: Options) -> Result {
	return convert_bytes(transmute([]u8)contents, source_path, opts)
}

// convert_bytes is the entry point for binary formats too (BSP).
convert_bytes :: proc(data: []u8, source_path: string, opts: Options) -> Result {
	contents := string(data)
	res: Result
	res.diagnostics = diag.init()
	res.source_format = opts.from
	if res.source_format == .Unknown {
		detected, by_content := detect_format(source_path, contents)
		res.source_format = detected
		if by_content {
			diag.info(
				&res.diagnostics,
				"io.format-sniffed",
				ir.concat("format detected from content: ", ir.format_name(detected)),
				source_path,
			)
		}
	}
	res.target_format = opts.to
	if !is_supported(res.source_format) {
		diag.err(
			&res.diagnostics,
			"convert.unsupported-source",
			ir.concat("no importer for format ", ir.format_name(res.source_format)),
			source_path,
		)
		return res
	}
	if !is_target_supported(res.target_format) {
		diag.err(
			&res.diagnostics,
			"convert.unsupported-target",
			ir.concat("no exporter for format ", ir.format_name(res.target_format)),
			source_path,
		)
		return res
	}

	// 1. Import into the IR.
	#partial switch res.source_format {
	case .Source_VMF:
		res.doc, res.diagnostics = vmf.import_document(contents, source_path)
	case .Source_BSP:
		res.doc, res.diagnostics = bsp.import_document(data, source_path)
	case .Unreal_T3D:
		res.doc, res.diagnostics = t3d.import_document(contents, source_path)
	case .UE3_Package:
		res.doc, res.diagnostics = ue3.import_document(data, source_path)
	case:
		return res
	}
	if diag.has_errors(&res.diagnostics) {
		return res
	}

	// 2. Coordinate and unit transformation, only when the frames differ.
	if engine_of(res.source_format) != engine_of(res.target_format) {
		target_cs := res.target_format == .Source_VMF ? xform.source_1() : xform.unreal_3()
		transform, ok := xform.transform_between(res.doc.cs, target_cs)
		if !ok {
			diag.err(&res.diagnostics, "convert.transform", "cannot build a transform between the two coordinate systems", source_path)
			return res
		}
		diag.info(
			&res.diagnostics,
			"convert.transform",
			transform_note(res.doc.cs, target_cs, transform),
			source_path,
		)
		apply_transform(&res.doc, transform, target_cs, &res.diagnostics)
	}

	// 3. Entity mapping through the profile.
	prof, found := profile.by_name(opts.profile_name)
	if !found {
		diag.warn(&res.diagnostics, "convert.unknown-profile", ir.concat("unknown profile '", opts.profile_name, "'; no entity mapping applied"), source_path)
	}
	if engine_of(res.source_format) != engine_of(res.target_format) {
		map_entities(&res.doc, prof, &res.diagnostics)
		map_entity_properties(&res.doc, prof, res.target_format, &res.diagnostics)
	}

	// 4. Validation of what is about to be written.
	validate_document(&res.doc, &res.diagnostics)
	if engine_of(res.source_format) != engine_of(res.target_format) {
		report_surface_loss(&res.doc, res.target_format, &res.diagnostics)
	}

	// 5. Serialize.
	#partial switch res.target_format {
	case .Source_VMF:
		res.output = vmf.export_document(&res.doc, &res.diagnostics)
	case .Unreal_T3D:
		res.output = t3d.export_document(&res.doc, &res.diagnostics)
	case:
		return res
	}

	if opts.report_materials {
		report_materials(&res.doc, &res.diagnostics)
	}
	summary_note(&res.doc, res.source_format, res.target_format, &res.diagnostics)
	res.ok = !diag.has_errors(&res.diagnostics)
	return res
}

transform_note :: proc(from, to: xform.CoordinateSystem, t: xform.Transform) -> string {
	b := strings.builder_make()
	strings.write_string(&b, ir.concat(from.name, " -> ", to.name, ": "))
	if t.mirrored {
		strings.write_string(&b, "handedness mirror, ")
	}
	strings.write_string(&b, ir.concat("unit scale ", geom.f64_string(t.scale), " (", to.name, " units per ", from.name, " unit)"))
	return strings.to_string(b)
}

// apply_transform rewrites the document into the target frame. Authored windings
// are transformed; derived windings are cleared so the exporter re-evaluates them
// from the (transformed) authored planes instead of double-approximating.
apply_transform :: proc(doc: ^ir.Document, t: xform.Transform, target: xform.CoordinateSystem, dg: ^diag.Diagnostics) {
	for &brush in doc.brushes {
		for &face in brush.faces {
			if transformed, ok := xform.apply_plane(t, face.plane); ok {
				face.plane = transformed
			} else {
				diag.warn(dg, "convert.degenerate-plane", "plane becomes degenerate under the transform", brush.id)
			}
			uv, ok := xform.apply_tex_projection(t, xform.TexProjection {
				u = face.uv.u,
				v = face.uv.v,
				u_offset = face.uv.u_offset,
				v_offset = face.uv.v_offset,
				u_scale = face.uv.u_scale,
				v_scale = face.uv.v_scale,
				rotation = face.uv.rotation,
			})
			if ok {
				face.uv.u = uv.u
				face.uv.v = uv.v
				face.uv.u_offset = uv.u_offset
				face.uv.v_offset = uv.v_offset
			} else {
				diag.warn(dg, "convert.degenerate-texture-axis", "texture projection becomes degenerate under the transform", brush.id)
			}
			// Windings are affine, so clipping in one frame and transforming the
			// result is equivalent to clipping in the target frame. Transforming
			// keeps the evaluated geometry available and avoids re-deriving it from
			// planes with an estimated bound.
			if len(face.winding) >= 3 {
				face.winding = xform.apply_winding(t, face.winding[:])
			}
		}
	}
	// Positions follow the frame change. Angles and rotators are engine semantics,
	// so they are converted by the property mapper, not here.
	transform_entity :: proc(e: ^ir.Entity, t: xform.Transform) {
		e.origin = xform.apply_point(t, e.origin)
	}
	transform_entity(&doc.world, t)
	for &entity in doc.entities {
		transform_entity(&entity, t)
	}
	doc.cs = target
}

map_entities :: proc(doc: ^ir.Document, prof: profile.Profile, dg: ^diag.Diagnostics) {
	// The new slice becomes doc.entities, so it must outlive this call.
	kept := make([dynamic]ir.Entity, 0, len(doc.entities))
	for &entity in doc.entities {
		target, mapped, note := profile.map_class(prof, entity.class_name)
		if !mapped {
				diag.warn(
					dg,
					"convert.unmapped-class",
					ir.concat("no mapping for entity class '", entity.class_name, "'; the class name is preserved"),
					entity.id,
				)
			// An unmapped class is kept as-is: its data is still the best available
			// representation, and the warning records the mismatch.
			append(&kept, entity)
			continue
		}
		if target == "" {
			if len(entity.brushes) > 0 {
				// Geometry-only actors (Unreal brush actors) have no counterpart as
				// an entity, but their solids still belong to the map.
				for brush_index in entity.brushes {
					append(&doc.world.brushes, brush_index)
				}
				diag.info(
					dg,
					"convert.entity-collapsed",
					ir.concat("entity class '", entity.class_name, "' has no target equivalent; its ", int_concat("", len(entity.brushes)), " brush(es) moved to the world"),
					entity.id,
				)
				continue
			}
			diag.info(
				dg,
				"convert.class-without-actor",
				ir.concat("source class '", entity.class_name, "' has no direct actor class: ", note),
				entity.id,
			)
			append(&kept, entity)
			continue
		}
		if target != entity.class_name {
			ir.push_property(&entity.props, "source_class", entity.class_name, entity.class_name)
			diag.info(
				dg,
				"convert.class-mapped",
				ir.concat(entity.class_name, " -> ", target, " (", note, ")"),
				entity.id,
			)
			entity.class_name = target
		}
		append(&kept, entity)
	}
	doc.entities = kept
}

report_materials :: proc(doc: ^ir.Document, dg: ^diag.Diagnostics) {
	seen := make(map[string]int, 8)
	defer delete(seen)
	for brush in doc.brushes {
		for face in brush.faces {
			if face.material == "" {
				continue
			}
			seen[face.material] += 1
		}
	}
	names := make([dynamic]string, 0, len(seen))
	defer delete(names)
	for name in seen {
		append(&names, name)
	}
	// Diagnostics must be deterministic: sort the names before reporting.
	plain := names[:]
	sort.sort(sort.slice_interface(&plain))
	for name in names {
		diag.info(
			dg,
			"convert.material-preserved",
			ir.concat(
				"material '",
				name,
				"' kept by name on ",
				int_concat("", seen[name]),
				" face(s); no asset is converted",
			),
			name,
		)
	}
}

summary_note :: proc(doc: ^ir.Document, from, to: ir.Format, dg: ^diag.Diagnostics) {
	faces := 0
	for brush in doc.brushes {
		faces += len(brush.faces)
	}
	diag.info(
		dg,
		"convert.summary",
		ir.concat(
			ir.format_name(from),
			" -> ",
			ir.format_name(to),
			": ",
			int_concat("", len(doc.brushes)),
			" brushes, ",
			int_concat("", faces),
			" faces, ",
			int_concat("", len(doc.entities) + 1),
			" entities",
		),
	)
}

// report_surface_loss records face-level data the target format cannot store. The
// adapters deliberately do not invent equivalents for these values.
report_surface_loss :: proc(doc: ^ir.Document, target: ir.Format, dg: ^diag.Diagnostics) {
	lightmap := 0
	smoothing := 0
	flags := 0
	for brush in doc.brushes {
		for face in brush.faces {
			if face.lightmap_scale != 0 && face.lightmap_scale != 16 {
				lightmap += 1
			}
			if face.smoothing_groups != 0 {
				smoothing += 1
			}
			if face.flags != 0 {
				flags += 1
			}
		}
	}
	#partial switch target {
	case .Unreal_T3D:
		if lightmap > 0 || smoothing > 0 {
			diag.warn(
				dg,
				"convert.surface-settings-dropped",
				fmt.aprintf(
					"%d face(s) with lightmap scale and %d with smoothing groups: T3D stores neither value, so both were dropped",
					lightmap,
					smoothing,
				),
			)
		}
	case .Source_VMF:
		if flags > 0 {
			diag.warn(
				dg,
				"convert.surface-flags-dropped",
				fmt.aprintf("%d face(s) with native surface flags: VMF sides have no flag field, so they were dropped", flags),
			)
		}
	}
}

// int_concat formats an int with an optional prefix.
int_concat :: proc(prefix: string, v: int) -> string {
	return ir.concat(prefix, fmt.aprintf("%d", v))
}

// validate_document collects structural problems that would make the output
// invalid or misleading. It never mutates authored data.
validate_document :: proc(doc: ^ir.Document, dg: ^diag.Diagnostics) {
	if len(doc.brushes) == 0 && len(doc.entities) == 0 {
		diag.warn(dg, "validate.empty-map", "the map has no geometry and no entities", doc.metadata.source_path)
	}
	planes := make([dynamic]geom.Plane, 0, 6)
	defer delete(planes)
	for &brush in doc.brushes {
		object := ir.concat("brush[", brush.id, "]")
		if len(brush.faces) < 4 {
			diag.warn(dg, "validate.brush-too-few-faces", "a convex brush needs at least four faces", object)
		}
		resize(&planes, 0)
		for &face in brush.faces {
			if !is_finite(face.plane.normal) || !is_finite_f64(face.plane.dist) {
				diag.err(dg, "validate.non-finite-plane", "plane has a non-finite normal or distance", object)
				continue
			}
			if n, ok := geom.normalize(face.plane.normal); ok {
				face.plane.normal = n
			} else {
				diag.err(dg, "validate.degenerate-plane", "plane normal has zero length", object)
			}
			append(&planes, face.plane)
			if face.material == "" {
				diag.warn(dg, "validate.face-without-material", "face has no material", object)
			}
			if face.winding_source == .Authored && len(face.winding) >= 3 {
				area := geom.polygon_area(face.winding[:])
				if area < geom.GEOM_EPSILON {
					diag.warn(dg, "validate.degenerate-winding", "authored polygon has no area", object)
				}
			}
		}
		// Convexity check on authored vertices: every vertex of the brush has to
		// stay behind every face plane (within tolerance).
		warned_non_convex := false
		for &face in brush.faces {
			if face.winding_source != .Authored || warned_non_convex {
				continue
			}
			for v in face.winding {
				for plane in planes {
					if geom.plane_distance(plane, v) > 1.0 {
						diag.warn(
							dg,
							"validate.non-convex-brush",
							"brush vertices are not inside every face plane; the brush is not a convex solid",
							object,
						)
						warned_non_convex = true
						break
					}
				}
				if warned_non_convex {
					break
				}
			}
		}
	}
	for &entity in doc.entities {
		if entity.class_name == "" {
			diag.err(dg, "validate.entity-without-class", "entity has no class name", entity.id)
		}
		if !is_finite(entity.origin) {
			diag.err(dg, "validate.non-finite-origin", "entity origin is not finite", entity.id)
		}
	}
}

is_finite :: proc(v: geom.Vec3) -> bool {
	return is_finite_f64(v.x) && is_finite_f64(v.y) && is_finite_f64(v.z)
}

is_finite_f64 :: proc(v: f64) -> bool {
	return !math.is_nan(v) && !math.is_inf(v)
}
