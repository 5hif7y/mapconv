package assets

import "core:testing"

@(test)
test_a_variant_suffix_names_the_material_it_came_from :: proc(t: ^testing.T) {
	// The compiler writes both forms: a blend patch and a static prop patch.
	cases := [?][2]string {
		{"agency/concrete/floor01_floor02_blend_wvt_patch", "agency/concrete/floor01_floor02_blend"},
		{"agency/plaster/plasterwall04a_-972_1348_577", "agency/plaster/plasterwall04a"},
		{"de_dust/tilefloor02_-1536_1152_112", "de_dust/tilefloor02"},
	}
	for item in cases {
		base, changed := strip_variant_suffix(item[0])
		testing.expect(t, changed, item[0])
		testing.expect_value(t, base, item[1])
	}
}

@(test)
test_a_plain_name_is_left_alone :: proc(t: ^testing.T) {
	for name in ([5]string{"de_dust/groundsand03", "de_dust2/groundsand03", "agency/wall/window01", "", "a_b_c"}) {
		base, changed := strip_variant_suffix(name)
		testing.expect(t, !changed, name)
		testing.expect_value(t, base, name)
	}
}

@(test)
test_a_three_number_suffix_only_is_not_a_patch :: proc(t: ^testing.T) {
	// Two runs of digits and one underscore do not form the _<x>_<y>_<z> tail.
	for name in ([3]string{"de_dust/floor_01_02", "de_dust/floor_1", "de_dust/01_02_03"}) {
		base, changed := strip_variant_suffix(name)
		testing.expect(t, !changed, name)
		testing.expect_value(t, base, name)
	}
}

@(test)
test_a_vmt_path_with_backslashes_becomes_a_path :: proc(t: ^testing.T) {
	testing.expect_value(t, forward_slashes("glass\\blinds_illuminated"), "glass/blinds_illuminated")
	testing.expect_value(t, forward_slashes("glass/blinds"), "glass/blinds")
}
