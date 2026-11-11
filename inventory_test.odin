package main

import "core:testing"

// The inventory is a declaration, so what it declares has to be checkable: an extension
// maps to one tier, a file declared a binary opens as one, and the same bytes always give
// the same digest.

@(test)
test_every_extension_is_declared_once :: proc(t: ^testing.T) {
	seen := make(map[string]bool, len(groups))
	defer delete(seen)
	for group in groups {
		testing.expect(t, !seen[group.ext], "an extension is declared twice")
		seen[group.ext] = true
		testing.expect(t, group.tier != "", "a declaration has no tier")
		testing.expect(t, group.reason != "", "a declaration has no reason")
	}
}

@(test)
test_the_tier_of_an_extension_is_the_one_declared :: proc(t: ^testing.T) {
	cases := [?]struct {
		extension: string,
		tier:      string,
	}{{".bsp", "T4"}, {".BSP", "T4"}, {".ccmap", "T1"}, {".vpk", "T5"}, {".dll", "T7"}, {".nav", "T7"}}
	for c in cases {
		extension := c.extension
		tier := c.tier
		info, declared := inventory_group(extension)
		testing.expectf(t, declared, "extension %q is not declared", extension)
		testing.expect_value(t, info.tier, tier)
	}
	_, declared := inventory_group(".not_a_format")
	testing.expect(t, !declared, "an unknown extension must not be declared")
}

@(test)
test_a_binary_is_checked_against_its_own_header :: proc(t: ^testing.T) {
	// A minimal PE image: MZ, e_lfanew at 0x3c, the PE signature, a machine and a
	// section count.
	pe: [0x60]u8
	pe[0] = 'M'
	pe[1] = 'Z'
	pe[0x3c] = 0x40
	pe[0x40] = 'P'
	pe[0x41] = 'E'
	pe[0x44] = 0x4c
	pe[0x45] = 0x01 // 0x014c, i386
	pe[0x46] = 1 // one section
	testing.expect(t, binary_header_ok(".dll", pe[:]))
	testing.expect(t, !binary_header_ok(".exe", []u8{'M', 'Z'}))
	pe[0x40] = 'X'
	testing.expect(t, !binary_header_ok(".dll", pe[:]))
	pe[0x40] = 'P'
	pe[0x44] = 0
	pe[0x45] = 0
	testing.expect(t, !binary_header_ok(".dll", pe[:]), "an unknown machine is not a PE")
}

@(test)
test_a_digest_is_the_same_for_the_same_bytes :: proc(t: ^testing.T) {
	first := digest_hex([]u8{0, 1, 2, 255})
	defer delete(first)
	second := digest_hex([]u8{0, 1, 2, 255})
	defer delete(second)
	testing.expect_value(t, first, second)
	testing.expect_value(t, len(first), 8)
	testing.expect_value(t, first, "000102ff")
}
