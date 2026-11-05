// Human-readable inspection of the canonical IR, used by `mapconv inspect`.
package convert

import "core:fmt"
import "core:sort"
import "core:strings"
import "../geom"
import "../ir"
import "../xform"

// inspect_document summarizes what the IR holds. It never mutates the document.
inspect_document :: proc(doc: ^ir.Document) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "format:      %s (%s)\n", ir.format_name(doc.metadata.format), doc.metadata.variant)
	if doc.metadata.source_path != "" {
		fmt.sbprintf(&b, "source:      %s\n", doc.metadata.source_path)
	}
	fmt.sbprintf(
		&b,
		"coordinates: %s, %s-handed, up=%s, %s units/meter\n",
		doc.cs.name,
		doc.cs.handedness == .Left ? "left" : "right",
		axis_name(doc.cs.up_axis),
		geom.f64_string(doc.cs.units_per_meter),
	)

	faces := 0
	authored := 0
	derived := 0
	for brush in doc.brushes {
		faces += len(brush.faces)
		for face in brush.faces {
			if face.winding_source == .Authored {
				authored += 1
			} else {
				derived += 1
			}
		}
	}
	subtractive := 0
	for brush in doc.brushes {
		if brush.op != .Add {
			subtractive += 1
		}
	}
	fmt.sbprintf(&b, "brushes:     %d (%d faces, %d subtractive/other CSG)\n", len(doc.brushes), faces, subtractive)
	fmt.sbprintf(&b, "windings:    %d authored, %d derived\n", authored, derived)
	fmt.sbprintf(&b, "entities:    %d (+ world %s)\n", len(doc.entities), doc.world.id)

	class_counts := make(map[string]int, 8)
	defer delete(class_counts)
	for entity in doc.entities {
		class_counts[entity.class_name] += 1
	}
	classes := make([dynamic]string, 0, len(class_counts))
	defer delete(classes)
	for name in class_counts {
		append(&classes, name)
	}
	plain_classes := classes[:]
	sort.sort(sort.slice_interface(&plain_classes))
	for name in plain_classes {
		fmt.sbprintf(&b, "  %-28s %d\n", name, class_counts[name])
	}

	material_faces := make(map[string]int, 8)
	defer delete(material_faces)
	for brush in doc.brushes {
		for face in brush.faces {
			if face.material != "" {
				material_faces[face.material] += 1
			}
		}
	}
	names := make([dynamic]string, 0, len(material_faces))
	defer delete(names)
	for name in material_faces {
		append(&names, name)
	}
	plain := names[:]
	sort.sort(sort.slice_interface(&plain))
	fmt.sbprintf(&b, "materials:   %d\n", len(names))
	for name in plain {
		fmt.sbprintf(&b, "  %-40s %d faces\n", name, material_faces[name])
	}

	bounds := ir.document_bounds(doc)
	fmt.sbprintf(
		&b,
		"bounds:      (%s) .. (%s)\n",
		geom.vec3_string(bounds.min, ", "),
		geom.vec3_string(bounds.max, ", "),
	)
	if len(doc.resources) > 0 {
		fmt.sbprintf(&b, "resources:   %d\n", len(doc.resources))
	}
	if len(doc.extensions) > 0 {
		fmt.sbprintf(&b, "extensions:  %d preserved block(s)\n", len(doc.extensions))
	}
	return strings.to_string(b)
}

axis_name :: proc(axis: u8) -> string {
	switch axis {
	case 0:
		return "X"
	case 1:
		return "Y"
	case 2:
		return "Z"
	}
	return "?"
}

// unit_note explains the unit scale of a coordinate system in one line.
unit_note :: proc(cs: xform.CoordinateSystem) -> string {
	return ir.concat(cs.name, ": ", geom.f64_string(cs.units_per_meter), " units per meter")
}
