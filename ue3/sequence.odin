// USeqAct_Interp keeps the transforms it saved while an interp was running.
//
// USeqAct_Interp::Serialize (Engine/Src/UnInterpolation.cpp:2649) is Super plus
// `Ar << SavedActorTransforms`, a TMap<AActor*, FSavedTransform>
// (Engine/Inc/EngineSequenceClasses.h:2034) whose comment in the source asks why it
// is written to disk at all. A cooked map never has any saved transform, so the
// payload ends with the empty map: a single count of zero.
//
// The reader accepts exactly that and nothing else, because there is no way to
// validate the pair layout without a non-empty case to measure against.
package ue3

import "core:fmt"
import "../diag"

read_seq_act_interp :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	head, head_d := read_object_head(pkg, pkg.exports[export_index], allocator, export_index)
	if diag.has_errors(&head_d) {
		d = head_d
		return
	}
	delete(head_d.items)
	if head.body_offset + 4 != head.end_offset {
		diag.err(
			&d,
			"ue3.unexpected-interp-tail",
			fmt.aprintf("%d trailing bytes instead of one empty map", head.end_offset - head.body_offset),
		)
		return
	}
	count := read_i32(&Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset})
	if count != 0 {
		diag.err(&d, "ue3.unexpected-interp-tail", fmt.aprintf("the saved transform map holds %d entries", count))
		return
	}
	return
}
