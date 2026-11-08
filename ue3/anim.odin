package ue3

import "core:fmt"
import "../diag"

// UAnimSequence (Engine/Src/UnSkeletalAnim.cpp) serializes, after the tags:
//
//   RawAnimationData : TArray<FRawAnimSequenceTrack>   (native since
//                      VER_NATIVE_RAWANIMDATA_SERIALIZATION)
//   NumBytes         : INT
//   SerializedData   : BYTE[NumBytes]                  (codec byte stream)
//
// Cooked packages normally ship an empty RawAnimationData, but the reader also
// walks non-empty tracks (FVector positions, FQuat rotations, optionally
// scaled tracks) so the exact-end check stays meaningful for every object.
Anim_Sequence :: struct {
	raw_tracks: int,
	bytes:      int,
}

read_anim_sequence :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Anim_Sequence, d: diag.Diagnostics) {
	d = diag.init()
	if export_index < 0 || export_index >= len(pkg.exports) {
		diag.err(&d, "ue3.bad-export", fmt.aprintf("export index %d out of range", export_index))
		return
	}
	e := pkg.exports[export_index]
	head, head_d := read_object_head(pkg, e, allocator)
	if diag.has_errors(&head_d) {
		// Ownership of the items moves to the caller: deleting them here and
		// again in the caller is a double free that kills the process.
		d = head_d
		return
	}
	defer delete(head_d.items)

	parse :: proc(r: ^Reader, end: int, scale: bool) -> (tracks: int, bytes: int, ok: bool) {
		count := read_i32(r)
		if r.failed || count < 0 || count > 100000 {
			return 0, 0, false
		}
		for _ in 0 ..< count {
			// PosTrack: TArray<FVector>
			n := read_i32(r)
			if r.failed || n < 0 || n > 1000000 {
				return 0, 0, false
			}
			if int(n) * 12 > end - r.pos {
				return 0, 0, false
			}
			r.pos += int(n) * 12
			// RotTrack: TArray<FQuat>
			n = read_i32(r)
			if r.failed || n < 0 || n > 1000000 {
				return 0, 0, false
			}
			if int(n) * 16 > end - r.pos {
				return 0, 0, false
			}
			r.pos += int(n) * 16
			if scale {
				n = read_i32(r)
				if r.failed || n < 0 || n > 1000000 || int(n) * 12 > end - r.pos {
					return 0, 0, false
				}
				r.pos += int(n) * 12
			}
		}
		num_bytes := read_i32(r)
		if r.failed || num_bytes < 0 || int(num_bytes) > end - r.pos {
			return 0, 0, false
		}
		r.pos += int(num_bytes)
		return int(count), int(num_bytes), true
	}

	// Before VER_NATIVE_RAWANIMDATA_SERIALIZATION the tracks live in the tagged
	// properties and the body is only the byte-stream length plus the bytes.
	direct := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
	if n := read_i32(&direct); !direct.failed && n >= 0 && int(n) <= head.end_offset - direct.pos {
		direct.pos += int(n)
		if direct.pos == head.end_offset {
			result.bytes = int(n)
			return
		}
	}

	for scale in ([]bool{false, true}) {
		r := Reader{data = pkg.data, pos = head.body_offset, limit = head.end_offset}
		tracks, bytes, ok := parse(&r, head.end_offset, scale)
		if ok && r.pos == head.end_offset {
			result.raw_tracks = tracks
			result.bytes = bytes
			return
		}
	}
	diag.err(&d, "ue3.anim-layout", "UAnimSequence did not consume the export")
	return
}
