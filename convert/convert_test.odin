package convert

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../diag"
import "../geom"
import "../ir"

VMF_FIXTURE :: "tests/fixtures/source/cube.vmf"
T3D_FIXTURE :: "tests/fixtures/unreal/cube.t3d"

read_fixture :: proc(t: ^testing.T, path: string) -> string {
	contents, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		testing.fail_now(t, "cannot read fixture")
	}
	return string(contents)
}

@(test)
test_detect_format_from_extension_and_content :: proc(t: ^testing.T) {
	format, by_content := detect_format("level.vmf", "")
	testing.expect_value(t, format, ir.Format.Source_VMF)
	testing.expect(t, !by_content)

	format2, by_content2 := detect_format("mislabelled.txt", "versioninfo\n{\n}\nworld\n{\n}\n")
	testing.expect_value(t, format2, ir.Format.Source_VMF)
	testing.expect(t, by_content2)

	format3, _ := detect_format("level.t3d", "")
	testing.expect_value(t, format3, ir.Format.Unreal_T3D)
}

@(test)
test_vmf_to_t3d :: proc(t: ^testing.T) {
	src := read_fixture(t, VMF_FIXTURE)
	result := convert_text(src, "cube.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	testing.expect(t, result.ok)
	testing.expect(t, !diag.has_errors(&result.diagnostics))
	testing.expect(t, strings.contains(result.output, "Begin Map"))
	testing.expect(t, strings.contains(result.output, "Begin PolyList"))
	testing.expect(t, strings.contains(result.output, "Class=PlayerStart"))
	testing.expect(t, strings.contains(result.output, "Class=Brush"))

	// 64 Source units are 162.56 Unreal units.
	found_scaled_plane := false
	for brush in result.doc.brushes {
		for face in brush.faces {
			if math.abs(face.plane.dist - 162.56) < 1e-6 {
				found_scaled_plane = true
			}
		}
	}
	testing.expect(t, found_scaled_plane, "the converted document must be in Unreal units")

	found_transform := false
	for item in result.diagnostics.items {
		if item.code == "convert.transform" {
			found_transform = true
		}
	}
	testing.expect(t, found_transform, "the coordinate transform must be reported")
}

@(test)
test_t3d_to_vmf_moves_brush_actors_into_the_world :: proc(t: ^testing.T) {
	src := read_fixture(t, T3D_FIXTURE)
	result := convert_text(src, "cube.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	testing.expect(t, result.ok)
	testing.expect(t, !diag.has_errors(&result.diagnostics))
	testing.expect_value(t, len(result.doc.world.brushes), 1)
	testing.expect_value(t, len(result.doc.entities), 1)
	testing.expect_value(t, result.doc.entities[0].class_name, "light")
	testing.expect(t, strings.contains(result.output, "worldspawn"))
	testing.expect(t, strings.contains(result.output, "solid"))
	testing.expect(t, strings.contains(result.output, "EngineMaterials.DefaultMaterial"))
	testing.expect(t, !strings.contains(result.output, "\"classname\" \"Brush\""))
}

@(test)
test_roundtrip_preserves_geometry :: proc(t: ^testing.T) {
	source := read_fixture(t, VMF_FIXTURE)
	to_unreal := convert_text(source, "cube.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	testing.expect(t, to_unreal.ok)

	back := convert_text(to_unreal.output, "cube.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	testing.expect(t, back.ok)
	testing.expect_value(t, len(back.doc.world.brushes), 1)
	back_brush := &back.doc.brushes[back.doc.world.brushes[0]]
	testing.expect_value(t, len(back_brush.faces), 6)

	original := convert_text(source, "cube.vmf", Options{to = .Source_VMF})
	original_brush := &original.doc.brushes[original.doc.world.brushes[0]]
	for face, i in back_brush.faces {
		want := original_brush.faces[i]
		testing.expectf(t, math.abs(face.plane.dist - want.plane.dist) < 1e-3, "face %d dist drifted", i)
		testing.expectf(t, geom.dot(face.plane.normal, want.plane.normal) > 0.999, "face %d normal drifted", i)
	}
}

@(test)
test_subtractive_brush_warns_when_targeting_vmf :: proc(t: ^testing.T) {
	src := `Begin Map Name=x
   Begin Level NAME=Level
      Begin Actor Class=Brush Name=Brush_0
         CsgOper=CSG_Subtract
         Begin Brush Name=Model_0
            Begin PolyList
               Begin Polygon Item=OUTSIDE
                  Origin 0,0,64
                  Normal 0,0,1
                  TextureU 0.01,0,0
                  TextureV 0,-0.01,0
                  Vertex 0,0,64
                  Vertex 0,64,64
                  Vertex 64,64,64
                  Vertex 64,0,64
               End Polygon
            End PolyList
         End Brush
      End Actor
   End Level
End Map
`
	result := convert_text(src, "subtract.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	found := false
	for item in result.diagnostics.items {
		if item.code == "vmf.csg-op-unsupported" {
			found = true
		}
	}
	testing.expect(t, found, "a subtractive brush cannot be expressed in VMF")
	testing.expect(t, result.ok, "the conversion still produces output, with a warning")
}

@(test)
test_unmapped_entity_class_is_reported :: proc(t: ^testing.T) {
	src := read_fixture(t, VMF_FIXTURE)
	result := convert_text(src, "cube.vmf", Options{to = .Unreal_T3D, profile_name = "default"})
	found := false
	for item in result.diagnostics.items {
		if item.code == "convert.unmapped-class" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_unsupported_target_is_an_error :: proc(t: ^testing.T) {
	src := read_fixture(t, VMF_FIXTURE)
	result := convert_text(src, "cube.vmf", Options{to = .Goldsrc_MAP})
	testing.expect(t, !result.ok)
	found := false
	for item in result.diagnostics.items {
		if item.code == "convert.unsupported-target" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_unknown_source_format_is_an_error :: proc(t: ^testing.T) {
	result := convert_text("not a map at all", "level.txt", Options{to = .Source_VMF})
	testing.expect(t, !result.ok)
}

@(test)
test_validate_flags_missing_material :: proc(t: ^testing.T) {
	src := read_fixture(t, VMF_FIXTURE)
	doc := convert_text(src, "cube.vmf", Options{to = .Source_VMF}).doc
	for &face in doc.brushes[0].faces {
		face.material = ""
	}
	diagnostics := diag.init()
	validate_document(&doc, &diagnostics)
	found := false
	for item in diagnostics.items {
		if item.code == "validate.face-without-material" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_source_light_maps_to_unreal_light_component :: proc(t: ^testing.T) {
	src := read_fixture(t, VMF_FIXTURE)
	result := convert_text(src, "cube.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	testing.expect(t, result.ok)

	light: ^ir.Entity
	for &entity in result.doc.entities {
		if entity.class_name == "PointLight" {
			light = &entity
		}
	}
	testing.expect(t, light != nil, "the Source light must map to a PointLight")
	color, has_color := ir.property_string(light.props[:], "LightColor")
	testing.expect(t, has_color)
	testing.expect_value(t, color, "(R=255,G=255,B=255,A=255)")
	brightness, has_brightness := ir.property_f64(light.props[:], "Brightness")
	testing.expect(t, has_brightness)
	testing.expect_value(t, brightness, f64(1))
	testing.expect(t, strings.contains(result.output, "LightColor=(R=255,G=255,B=255,A=255)"))
	testing.expect(t, strings.contains(result.output, "Brightness=1"))
	testing.expect(t, !strings.contains(result.output, "_light"), "the Source key must not leak into T3D")
}

@(test)
test_unreal_light_maps_back_to_source :: proc(t: ^testing.T) {
	src := read_fixture(t, T3D_FIXTURE)
	result := convert_text(src, "cube.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	testing.expect(t, result.ok)
	light: ^ir.Entity
	for &entity in result.doc.entities {
		if entity.class_name == "light" {
			light = &entity
		}
	}
	testing.expect(t, light != nil)
	value, has_value := ir.property_string(light.props[:], "_light")
	testing.expect(t, has_value)
	testing.expect_value(t, value, "255 200 150 200")
	testing.expect(t, !strings.contains(result.output, "Brightness="), "Unreal keys must not leak into VMF")
}

@(test)
test_rotation_maps_both_directions :: proc(t: ^testing.T) {
	// Source angles (pitch yaw roll) -> Unreal rotator (65536 units per turn).
	source := read_fixture(t, VMF_FIXTURE)
	to_unreal := convert_text(source, "cube.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	start: ^ir.Entity
	for &entity in to_unreal.doc.entities {
		if entity.class_name == "PlayerStart" {
			start = &entity
		}
	}
	testing.expect(t, start != nil)
	testing.expect(t, start.has_rotation)
	testing.expect_value(t, start.rotation.pitch, i32(0))
	testing.expect_value(t, start.rotation.yaw, i32(-16384)) // 90 degrees, mirrored
	testing.expect_value(t, start.rotation.roll, i32(0))
	testing.expect(t, start.angles == geom.VEC3_ZERO)

	// And back: Unreal yaw 16384 -> Source yaw -90.
	unreal := read_fixture(t, T3D_FIXTURE)
	to_source := convert_text(unreal, "cube.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	for entity in to_source.doc.entities {
		if entity.class_name == "light" {
			testing.expect(t, !entity.has_rotation)
			testing.expect(t, math.abs(entity.angles.y + 90) < 1e-6, "Unreal yaw 90 degrees must become Source yaw -90")
		}
	}
}

@(test)
test_unmapped_property_is_reported_and_dropped :: proc(t: ^testing.T) {
	src := `versioninfo
{
	"formatversion" "100"
}
world
{
	"id" "1"
	"classname" "worldspawn"
}
entity
{
	"id" "10"
	"classname" "light"
	"origin" "0 0 64"
	"_light" "255 255 255 200"
	"_custom_thing" "42"
}
`
	result := convert_text(src, "custom.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	testing.expect(t, result.ok)
	found := false
	for item in result.diagnostics.items {
		if item.code == "convert.property-unmapped" && strings.contains(item.message, "_custom_thing") {
			found = true
		}
	}
	testing.expect(t, found, "unmapped properties must be reported")
	testing.expect(t, !strings.contains(result.output, "_custom_thing"))
}

@(test)
test_surface_flags_are_reported_when_targeting_vmf :: proc(t: ^testing.T) {
	src := read_fixture(t, T3D_FIXTURE)
	result := convert_text(src, "cube.t3d", Options{to = .Source_VMF, profile_name = "unreal3-to-source1"})
	found := false
	for item in result.diagnostics.items {
		if item.code == "convert.surface-flags-dropped" {
			found = true
		}
	}
	testing.expect(t, found, "T3D surface flags have no VMF field and must be reported")
}

@(test)
test_targetname_maps_to_tag :: proc(t: ^testing.T) {
	src := `versioninfo
{
	"formatversion" "100"
}
world
{
	"id" "1"
	"classname" "worldspawn"
}
entity
{
	"id" "10"
	"classname" "logic_relay"
	"targetname" "relay_one"
}
`
	result := convert_text(src, "relay.vmf", Options{to = .Unreal_T3D, profile_name = "source1-to-unreal3"})
	for entity in result.doc.entities {
		if value, ok := ir.property_string(entity.props[:], "Tag"); ok {
			testing.expect_value(t, value, "relay_one")
			return
		}
	}
	testing.expect(t, false, "targetname should become Tag")
}
