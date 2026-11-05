package t3d

import "core:math"
import "core:os"
import "core:testing"
import "../diag"
import "../geom"
import "../ir"

FIXTURE :: "tests/fixtures/unreal/cube.t3d"

read_fixture :: proc(t: ^testing.T, path: string) -> string {
	contents, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		testing.fail_now(t, "cannot read fixture")
	}
	return string(contents)
}

@(test)
test_tokenize_line_respects_quotes :: proc(t: ^testing.T) {
	tokens := tokenize_line("Begin Actor Class=Brush Name=Brush_0 Archetype=Brush'Engine.Default__Brush'")
	testing.expect_value(t, len(tokens), 5)
	testing.expect_value(t, tokens[2], "Class=Brush")
	testing.expect_value(t, tokens[4], "Archetype=Brush'Engine.Default__Brush'")
}

@(test)
test_parse_ue_vec_and_rotation :: proc(t: ^testing.T) {
	v, ok := parse_ue_vec("(X=1.5,Y=-2,Z=3)")
	testing.expect(t, ok)
	testing.expect_value(t, v, geom.vec3(1.5, -2, 3))
	v2, ok2 := parse_ue_vec("+0064.000000,-0064.000000,+0000.000000")
	testing.expect(t, ok2)
	testing.expect_value(t, v2, geom.vec3(64, -64, 0))
	r, ok3 := parse_ue_rotation("(Pitch=10,Yaw=-90,Roll=5)")
	testing.expect(t, ok3)
	testing.expect_value(t, r.pitch, i32(10))
	testing.expect_value(t, r.yaw, i32(-90))
	testing.expect_value(t, r.roll, i32(5))
}

@(test)
test_parse_tree_nesting :: proc(t: ^testing.T) {
	src := `Begin Map Name=test
   Begin Level NAME=Level
      Begin Actor Class=Brush Name=Brush_0
         CsgOper=CSG_Add
         Begin Brush Name=Model_0
            Begin PolyList
               Begin Polygon Item=OUTSIDE
                  Vertex 1,2,3
               End Polygon
            End PolyList
         End Brush
      End Actor
   End Level
End Map
`
	diagnostics := diag.init()
	tree := parse_tree(src, &diagnostics, "inline")
	testing.expect_value(t, len(tree.roots), 1)
	testing.expect_value(t, tree.roots[0].keyword, "map")
	testing.expect_value(t, len(tree.roots[0].children), 1)
	level := tree.roots[0].children[0]
	testing.expect_value(t, level.keyword, "level")
	testing.expect_value(t, len(level.children), 1)
	actor := level.children[0]
	testing.expect_value(t, actor.keyword, "actor")
	testing.expect_value(t, len(actor.data), 1)
	testing.expect_value(t, actor.data[0].key, "csgoper")
	brush, has_brush := child_by_keyword(&actor, "brush")
	testing.expect(t, has_brush)
	testing.expect_value(t, len(brush.children), 1)
}

@(test)
test_import_fixture :: proc(t: ^testing.T) {
	src := read_fixture(t, FIXTURE)
	doc, diagnostics := import_document(src, "cube.t3d")
	testing.expect(t, !diag.has_errors(&diagnostics))
	testing.expect_value(t, len(doc.brushes), 1)
	brush := doc.brushes[0]
	testing.expect_value(t, brush.op, ir.Csg_Op.Add)
	testing.expect_value(t, len(brush.faces), 6)
	for face in brush.faces {
		testing.expect_value(t, face.material, "EngineMaterials.DefaultMaterial")
		testing.expect(t, len(face.winding) == 4)
		testing.expect(t, face.winding_source == .Authored)
		testing.expect(t, face.flags == 1)
		item, has_item := ir.property_string(face.props[:], "t3d.item")
		testing.expect(t, has_item)
		testing.expect_value(t, item, "OUTSIDE")
	}
	testing.expect_value(t, len(doc.entities), 2)
	testing.expect_value(t, doc.entities[0].class_name, "Brush")
	testing.expect_value(t, len(doc.entities[0].brushes), 1)
	light := doc.entities[1]
	testing.expect_value(t, light.class_name, "PointLight")
	testing.expect_value(t, light.origin, geom.vec3(0, 0, 192))
	testing.expect(t, light.has_rotation)
	testing.expect_value(t, light.rotation.yaw, i32(90))
	brightness, has_brightness := ir.property_f64(light.props[:], "brightness")
	testing.expect(t, has_brightness)
	testing.expect_value(t, brightness, f64(200))
}

@(test)
test_export_import_roundtrip :: proc(t: ^testing.T) {
	src := read_fixture(t, FIXTURE)
	first, first_diag := import_document(src, "cube.t3d")
	testing.expect(t, !diag.has_errors(&first_diag))

	export_diag := diag.init()
	text := export_document(&first, &export_diag)
	testing.expect_value(t, diag.count(&export_diag, .Error), 0)

	second, second_diag := import_document(text, "roundtrip.t3d")
	testing.expect(t, !diag.has_errors(&second_diag))
	testing.expect_value(t, len(second.brushes), len(first.brushes))
	testing.expect_value(t, len(second.brushes[0].faces), len(first.brushes[0].faces))
	testing.expect_value(t, len(second.entities), len(first.entities))

	for face, i in second.brushes[0].faces {
		original := first.brushes[0].faces[i]
		testing.expect(t, math.abs(face.plane.dist - original.plane.dist) < 1e-5)
		testing.expect(t, geom.approx_equal(face.plane.normal, original.plane.normal, 1e-6))
		testing.expect(t, len(face.winding) == len(original.winding))
		testing.expect_value(t, face.material, original.material)
		testing.expect_value(t, face.flags, original.flags)
	}
}

@(test)
test_malformed_input_is_reported :: proc(t: ^testing.T) {
	src := `Begin Map
   Begin Level NAME=Level
      Begin Actor Class=Brush Name=Brush_0
   End Level
End Map
`
	doc, diagnostics := import_document(src, "broken.t3d")
	testing.expect(t, diag.count(&diagnostics, .Warning) >= 1)
	testing.expect_value(t, len(doc.entities), 1)
}

@(test)
test_missing_map_is_an_error :: proc(t: ^testing.T) {
	_, diagnostics := import_document("Begin Level NAME=Level\nEnd Level\n", "nomap.t3d")
	testing.expect(t, diag.has_errors(&diagnostics))
}

@(test)
test_geometry_only_fragment_is_imported :: proc(t: ^testing.T) {
	src := `Begin PolyList
   Begin Polygon Item=OUTSIDE
      Origin 0,0,0
      Normal 0,0,1
      TextureU 0.01,0,0
      TextureV 0,-0.01,0
      Vertex 0,0,0
      Vertex 0,64,0
      Vertex 64,64,0
      Vertex 64,0,0
   End Polygon
End PolyList
`
	doc, diagnostics := import_document(src, "fragment.t3d")
	testing.expect(t, diag.count(&diagnostics, .Warning) >= 1)
	testing.expect_value(t, len(doc.brushes), 1)
	testing.expect_value(t, len(doc.brushes[0].faces), 1)
}
