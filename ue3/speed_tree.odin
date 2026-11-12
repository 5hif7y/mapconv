package ue3

import "core:fmt"
import "../diag"

// USpeedTree::Serialize (Engine/Src/SpeedTree.cpp:1028) has two shapes. The structured
// one (:1033, taken when the build keeps the SpeedTree 5 supporting data) writes the
// collision objects, the wind parameters, the buffers and the render elements through
// UE3 types. The legacy one (:1182) writes a declared length and the SDK's own blob.
//
// All 136 SpeedTree objects of the corpus take the legacy path, and that is a measurement
// with a magic in it, not a declaration: after the length word the payload opens with
// `count`, `header length` and the container signature "__IdvSpt_02_", which is SpeedTree's
// own format ("Idv" is IDV, the vendor). A structured asset would not have that signature,
// and this reader refuses one instead of skipping it, so the claim cannot silently rot.
//
// What is interpreted is the envelope plus that header: the declared length has to equal
// the bytes that follow it, the header has to be inside the block, and the rest is the
// licensed container this toolkit does not read. Three falsifiers keep it honest.
Speed_Tree :: struct {
	payload: i32,
	// signature is the container the payload opens with, kept so a caller can report
	// which shape the asset took instead of assuming one.
	signature: string,
	header_bytes: i32,
}

// SPEEDTREE_SIGNATURE is the container signature of the SDK's own format, 12 bytes long.
SPEEDTREE_SIGNATURE :: "__IdvSpt_02_"

read_speed_tree :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Speed_Tree, d: diag.Diagnostics) {
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
	return decode_speed_tree_body(pkg.data, head.body_offset, head.end_offset)
}

// decode_speed_tree_body is the payload, split out so a test can hand it bytes.
decode_speed_tree_body :: proc(data: []u8, body_offset, end_offset: int) -> (result: Speed_Tree, d: diag.Diagnostics) {
	d = diag.init()
	r := Reader{data = data, pos = body_offset, limit = end_offset}
	bytes := read_i32(&r)
	if r.failed || bytes < 0 || int(bytes) != r.limit - r.pos {
		diag.err(&d, "ue3.bad-speedtree", fmt.aprintf("declared size %d does not match %d remaining bytes", bytes, r.limit - r.pos))
		return
	}
	// The SDK container header: a word, the length of the signature, the signature.
	marker := read_i32(&r)
	signature_length := int(read_i32(&r))
	if r.failed || signature_length < 1 || signature_length > 64 || r.pos + signature_length > r.limit {
		diag.err(&d, "ue3.bad-speedtree", fmt.aprintf("the container header is not in the block (marker %d, length %d)", marker, signature_length))
		return
	}
	signature := string(data[r.pos:r.pos + signature_length])
	r.pos += signature_length
	if signature != SPEEDTREE_SIGNATURE {
		// The structured branch this reader does not implement: say so rather than
		// consume it as if it were the container.
		diag.err(&d, "ue3.speedtree-structured",
			fmt.aprintf("a structured SpeedTree payload (%q), which this reader does not implement", signature))
		return
	}
	result.signature = SPEEDTREE_SIGNATURE
	result.header_bytes = i32(r.pos - (body_offset + 4))
	result.payload = bytes
	r.pos = r.limit
	return
}
