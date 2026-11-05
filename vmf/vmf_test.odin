package vmf

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../diag"
import "../geom"
import "../ir"
import "../xform"

// Tests run from the module root, so fixture paths are module-relative.
FIXTURE :: "tests/fixtures/source/cube.vmf"

read_fixture :: proc(t: ^testing.T, path: string) -> string {
	contents, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		testing.fail_now(t, "cannot read fixture")
	}
	return string(contents)
}

@(test)
test_tokenizer_handles_escapes_and_comments :: proc(t: ^testing.T) {
	tokens := tokenize("\"a\\\"b\" // trailing comment\nworld\n{\n}\n")
	testing.expect(t, len(tokens) == 5)
	testing.expect_value(t, tokens[0].kind, Token_Kind.String)
	testing.expect_value(t, tokens[0].text, "a\"b")
	testing.expect_value(t, tokens[1].kind, Token_Kind.Word)
	testing.expect_value(t, tokens[1].text, "world")
	testing.expect_value(t, tokens[2].kind, Token_Kind.Open_Brace)
	testing.expect_value(t, tokens[3].kind, Token_Kind.Close_Brace)
}

@(test)
test_parse_plane :: proc(t: ^testing.T) {
	plane, ok := parse_plane("(64 64 64) (64 -64 64) (-64 -64 64)")
	testing.expect(t, ok)
	testing.expect(t, math.abs(plane.normal.z - 1) < 1e-12)
	testing.expect(t, math.abs(plane.dist - 64) < 1e-12)
}

@(test)
test_parse_tex_axis :: proc(t: ^testing.T) {
	axis, scale, offset, ok := parse_tex_axis("[1 0 0 32] 0.25")
	testing.expect(t, ok)
	testing.expect(t, math.abs(axis.x - 1) < 1e-12)
	testing.expect(t, math.abs(axis.y) < 1e-12)
	testing.expect(t, math.abs(axis.z) < 1e-12)
	testing.expect(t, math.abs(scale - 0.25) < 1e-12)
	testing.expect(t, math.abs(offset - 32) < 1e-12)
}

@(test)
test_import_fixture :: proc(t: ^testing.T) {
	src := read_fixture(t, FIXTURE)
	doc, diagnostics := import_document(src, "cube.vmf")
	testing.expect(t, !diag.has_errors(&diagnostics))
	testing.expect_value(t, len(doc.brushes), 1)
	brush := doc.brushes[0]
	testing.expect_value(t, len(brush.faces), 6)
	testing.expect_value(t, brush.op, ir.Csg_Op.Add)

	for face in brush.faces {
		testing.expect_value(t, face.material, "DEV/DEV_MEASUREGENERIC01")
		testing.expect(t, math.abs(face.uv.u_scale - 0.25) < 1e-12)
		testing.expect(t, face.winding_source == .Derived)
		testing.expect(t, len(face.winding) == 4, "each cube side should evaluate to a quad")
	}

	testing.expect_value(t, len(doc.entities), 2)
	testing.expect_value(t, doc.entities[0].class_name, "light")
	testing.expect_value(t, doc.entities[0].origin, geom.vec3(0, 0, 96))
	testing.expect_value(t, doc.entities[1].class_name, "info_player_start")
	testing.expect_value(t, len(doc.materials), 1)
	testing.expect_value(t, doc.metadata.variant, "vmf/100")
}

@(test)
test_unknown_side_key_is_namespaced :: proc(t: ^testing.T) {
	src := `
world
{
	"id" "1"
	"classname" "worldspawn"
	solid
	{
		"id" "2"
		side
		{
			"id" "3"
			"plane" "(64 64 64) (64 -64 64) (-64 -64 64)"
			"material" "DEV/DEV_MEASUREGENERIC01"
			"custom_key" "custom value"
		}
	}
}
`
	doc, diagnostics := import_document(src, "unknown.vmf")
	testing.expect(t, !diag.has_errors(&diagnostics))
	value, ok := ir.property_string(doc.brushes[0].faces[0].props[:], "vmf.custom_key")
	testing.expect(t, ok)
	testing.expect_value(t, value, "custom value")
}

@(test)
test_export_import_roundtrip :: proc(t: ^testing.T) {
	src := read_fixture(t, FIXTURE)
	first, first_diag := import_document(src, "cube.vmf")
	testing.expect(t, !diag.has_errors(&first_diag))

	export_diag := diag.init()
	text := export_document(&first, &export_diag)
	testing.expect_value(t, diag.count(&export_diag, .Error), 0)
	testing.expect(t, strings.contains(text, "world\n{"))

	second, second_diag := import_document(text, "roundtrip.vmf")
	testing.expect(t, !diag.has_errors(&second_diag))
	testing.expect_value(t, len(second.brushes), len(first.brushes))
	testing.expect_value(t, len(second.brushes[0].faces), len(first.brushes[0].faces))
	testing.expect_value(t, len(second.entities), len(first.entities))

	for face, i in second.brushes[0].faces {
		original := first.brushes[0].faces[i]
		testing.expect(t, geom_plane_close(face.plane, original.plane))
		testing.expect_value(t, face.material, original.material)
		testing.expect(t, math.abs(face.uv.u_offset - original.uv.u_offset) < 1e-9)
		testing.expect(t, math.abs(face.uv.u_scale - original.uv.u_scale) < 1e-9)
	}
	for entity, i in second.entities {
		testing.expect_value(t, entity.class_name, first.entities[i].class_name)
		testing.expect(t, entity.origin == first.entities[i].origin)
	}
	// Unknown world key survives the round trip.
	skyname, ok := ir.property_string(second.world.props[:], "skyname")
	testing.expect(t, ok)
	testing.expect_value(t, skyname, "sky_day01_01")
}

@(test)
test_malformed_input_reports_errors :: proc(t: ^testing.T) {
	src := `world
{
	"classname" "worldspawn"
	solid
	{
		side
		{
			"plane" "(0 0 0) (1 0 0) (2 0 0)"
		}
	}
`
	doc, diagnostics := import_document(src, "broken.vmf")
	testing.expect(t, diag.has_errors(&diagnostics), "a degenerate plane must be an error")
	testing.expect(t, diag.count(&diagnostics, .Error) >= 1)
	_ = doc
}

@(test)
test_empty_file_is_an_error :: proc(t: ^testing.T) {
	_, diagnostics := import_document("", "empty.vmf")
	testing.expect(t, diag.has_errors(&diagnostics))
}

@(test)
test_subtractive_operation_is_reported_on_export :: proc(t: ^testing.T) {
	doc := ir.init_document(.Source_VMF, xform.source_1())
	brush := ir.make_brush("1", .Subtract)
	append(&brush.faces, ir.make_face({geom.Vec3{0, 0, 1}, 64}, ir.default_tex_projection(), "DEV/DEV_MEASUREGENERIC01"))
	append(&brush.faces, ir.make_face({geom.Vec3{0, 0, -1}, 64}, ir.default_tex_projection(), "DEV/DEV_MEASUREGENERIC01"))
	append(&brush.faces, ir.make_face({geom.Vec3{1, 0, 0}, 64}, ir.default_tex_projection(), "DEV/DEV_MEASUREGENERIC01"))
	append(&brush.faces, ir.make_face({geom.Vec3{-1, 0, 0}, 64}, ir.default_tex_projection(), "DEV/DEV_MEASUREGENERIC01"))
	append(&doc.world.brushes, ir.add_brush(&doc, brush))

	diagnostics := diag.init()
	_ = export_document(&doc, &diagnostics)
	testing.expect(t, diag.count(&diagnostics, .Warning) >= 1)
	found := false
	for item in diagnostics.items {
		if item.code == "vmf.csg-op-unsupported" {
			found = true
		}
	}
	testing.expect(t, found, "exporting a subtractive brush to VMF must warn")
}

geom_plane_close :: proc(a, b: geom.Plane) -> bool {
	return math.abs(a.dist - b.dist) < 1e-6 && a.normal == b.normal
}
