package vpk

import "core:testing"
import "../diag"

// The tests build a version 2 tree: one extension, two directories, an empty
// directory inside the first one and a file with no extension under a space.
Tree_Builder :: struct {
	data: [dynamic]u8,
}

put_string :: proc(b: ^Tree_Builder, text: string) {
	append(&b.data, ..transmute([]u8)text)
	append(&b.data, 0)
}

put_record :: proc(b: ^Tree_Builder, crc: u32, offset, length: u32) {
	append(&b.data, u8(crc & 0xff), u8((crc >> 8) & 0xff), u8((crc >> 16) & 0xff), u8((crc >> 24) & 0xff))
	append(&b.data, 0, 0) // preload
	append(&b.data, 0, 0) // archive 0
	append(&b.data, u8(offset & 0xff), u8((offset >> 8) & 0xff), u8((offset >> 16) & 0xff), u8((offset >> 24) & 0xff))
	append(&b.data, u8(length & 0xff), u8((length >> 8) & 0xff), u8((length >> 16) & 0xff), u8((length >> 24) & 0xff))
	append(&b.data, 0xff, 0xff) // terminator
}

build_vpk :: proc() -> []u8 {
	tree: Tree_Builder
	// Extension "vmt" with directory "materials/dev" holding two files, then an
	// empty directory (which closes the extension).
	put_string(&tree, "vmt")
	put_string(&tree, "materials/dev")
	put_string(&tree, "one")
	put_record(&tree, 1, 0, 10)
	put_string(&tree, "two")
	put_record(&tree, 2, 10, 20)
	put_string(&tree, "") // end of the files of this directory
	put_string(&tree, "") // end of the directories of this extension
	// No extension: stored under a single space.
	put_string(&tree, " ")
	put_string(&tree, "root")
	put_string(&tree, "readme")
	put_record(&tree, 3, 30, 5)
	put_string(&tree, "")
	put_string(&tree, "")
	put_string(&tree, "") // end of the extensions

	out: [dynamic]u8
	put_u32(&out, 0x55AA1234) // signature
	put_u32(&out, 2)          // version
	put_u32(&out, u32(len(tree.data))) // tree size
	put_u32(&out, 0) // file data section size
	put_u32(&out, 0) // archive md5 section size
	put_u32(&out, 0) // other md5 section size
	put_u32(&out, 0) // signature section size
	append(&out, ..tree.data[:])
	return out[:]
}

put_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value & 0xff), u8((value >> 8) & 0xff), u8((value >> 16) & 0xff), u8((value >> 24) & 0xff))
}

@(test)
test_tree_is_nested_and_terminated :: proc(t: ^testing.T) {
	data := build_vpk()
	defer delete(data)
	tree, d := parse_bytes(data)
	defer destroy(&tree)
	testing.expectf(t, !diag_has_errors(d), "the tree did not parse")
	testing.expect_value(t, len(tree.entries), 3)
	if len(tree.entries) < 3 {
		return
	}
	entry, _, found := lookup(&tree, "materials/dev/two.vmt")
	testing.expect(t, found, "materials/dev/two.vmt was not found")
	testing.expect_value(t, entry.length, 20)
	testing.expect_value(t, entry.crc, u32(2))
	// A file without an extension lives under a single space in the tree but is
	// named without one.
	plain, _, plain_found := lookup(&tree, "root/readme.")
	testing.expect(t, plain_found, "root/readme was not found")
	testing.expect_value(t, plain.ext, "")
}

@(test)
test_a_truncated_tree_is_reported :: proc(t: ^testing.T) {
	data := build_vpk()
	defer delete(data)
	short := data[:len(data) - 4]
	tree, d := parse_bytes(short)
	testing.expect(t, diag_has_errors(d), "a truncated tree has to be reported")
	destroy(&tree)
}

diag_has_errors :: proc(d: diag.Diagnostics) -> bool {
	for item in d.items {
		if item.severity == .Error {
			return true
		}
	}
	return false
}
