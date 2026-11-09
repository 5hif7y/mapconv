package ue3

import "core:fmt"
import "../diag"

// USoundCue::Serialize (Engine/Src/UnAudioNodes.cpp:203): after the tagged
// properties it only writes EditorData, a TMap<USoundNode*,
// FSoundNodeEditorData> whose value is two INTs (EngineClasses.h:20909).
Sound_Cue :: struct {
	editor_entries: int,
}

read_sound_cue :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Sound_Cue, d: diag.Diagnostics) {
	d = diag.init()
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
		diag.err(&d, "ue3.bad-sound-cue", fmt.aprintf("implausible editor map count %d", count))
		return
	}
	if i64(count) * 12 > i64(r.limit - r.pos) {
		diag.err(&d, "ue3.bad-sound-cue", "editor map overruns the export")
		return
	}
	r.pos += int(count) * 12
	result.editor_entries = int(count)
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.sound-cue-layout", fmt.aprintf("USoundCue consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
