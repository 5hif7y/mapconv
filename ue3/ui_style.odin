// UIStyle: a UI style object and its trailing state table.
//
// The tag stream covers the style properties; what is left is a TMap with eight
// byte records, an object reference and an integer (UnTemplate.h), which is how
// the cooked styles carry their state data. Measured on every style of the
// corpus: four byte count, then that many pairs, and the pair references resolve
// against the package tables. A count that does not consume the export exactly is
// rejected instead of being credited.
package ue3

import "core:fmt"
import "../diag"

Ui_Style :: struct {
	export_index: int,
	pairs:        int,
}

read_ui_style :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (style: Ui_Style, d: diag.Diagnostics) {
	d = diag.init()
	style.export_index = export_index
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	defer delete(head_d.items)
	r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	count := read_i32(&r)
	if r.failed || count < 0 || count > 1_000_000 {
		diag.err(&d, "ue3.bad-ui-style", fmt.aprintf("implausible style pair count %d", count))
		return
	}
	for i in 0 ..< int(count) {
		reference := read_i32(&r)
		value := read_i32(&r)
		if r.failed || !valid_object_reference(pkg, reference) {
			diag.err(&d, "ue3.bad-ui-style", fmt.aprintf("style pair %d holds reference %d", i, reference))
			return
		}
		_ = value
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.bad-ui-style", fmt.aprintf("style table consumed %d of %d tail bytes", r.pos, head.end_offset))
		return
	}
	style.pairs = int(count)
	return
}
