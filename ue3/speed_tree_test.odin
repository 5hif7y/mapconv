package ue3

import "core:testing"

import "../diag"

// The SpeedTree payload is the SDK's own container, and the claim that the corpus takes
// the legacy path rests on three checks: the length word closes the block, the header
// lives inside it, and the signature is the one the SDK writes. Each is falsified here.

Speed_Tree_Offsets :: struct {
	length:  int,
	marker:  int,
	header_length: int,
	signature: int,
}

st_put_i32 :: proc(data: []u8, at: int, value: i32) {
	bits := u32(value)
	data[at + 0] = u8(bits)
	data[at + 1] = u8(bits >> 8)
	data[at + 2] = u8(bits >> 16)
	data[at + 3] = u8(bits >> 24)
}

build_speed_tree_body :: proc(signature: string) -> (data: []u8, at: Speed_Tree_Offsets) {
	block := 4 + 4 + 4 + len(signature) + 32
	data = make([]u8, block)
	at.length = 0
	st_put_i32(data, 0, i32(block - 4))
	at.marker = 4
	st_put_i32(data, 4, 1000)
	at.header_length = 8
	st_put_i32(data, 8, i32(len(signature)))
	at.signature = 12
	copy(data[12:], signature)
	// The licensed container: opaque bytes, they only have to be there.
	for k in 0 ..< 32 {
		data[12 + len(signature) + k] = u8(0x40 + k)
	}
	return data[:block], at
}

@(test)
test_a_legacy_speed_tree_payload_is_bounded_and_signed :: proc(t: ^testing.T) {
	data, _ := build_speed_tree_body(SPEEDTREE_SIGNATURE)
	defer delete(data)
	result, d := decode_speed_tree_body(data, 0, len(data))
	defer delete(d.items)
	testing.expectf(t, !diag.has_errors(&d), "a clean payload was refused: %s",
		d.items[0].message if len(d.items) > 0 else "")
	testing.expect_value(t, result.payload, i32(len(data) - 4))
	testing.expect_value(t, result.header_bytes, i32(8 + len(SPEEDTREE_SIGNATURE)))
	testing.expect_value(t, result.signature, SPEEDTREE_SIGNATURE)
}

@(test)
test_a_speed_tree_payload_whose_length_does_not_close_is_refused :: proc(t: ^testing.T) {
	data, at := build_speed_tree_body(SPEEDTREE_SIGNATURE)
	defer delete(data)
	st_put_i32(data, at.length, i32(len(data) - 8))
	_, d := decode_speed_tree_body(data, 0, len(data))
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect(t, len(d.items) > 0 && d.items[0].code == "ue3.bad-speedtree")
}

@(test)
test_a_structured_speed_tree_payload_is_refused_not_skipped :: proc(t: ^testing.T) {
	// A build that keeps the SpeedTree 5 supporting data writes collision objects and
	// buffers here, not a container. Reading it as one would credit bytes this reader
	// never looked at, so it is refused by name.
	data, _ := build_speed_tree_body("not a container")
	defer delete(data)
	_, d := decode_speed_tree_body(data, 0, len(data))
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].code, "ue3.speedtree-structured")
}

@(test)
test_a_speed_tree_header_that_is_not_inside_the_block_is_refused :: proc(t: ^testing.T) {
	data, at := build_speed_tree_body(SPEEDTREE_SIGNATURE)
	defer delete(data)
	st_put_i32(data, at.header_length, 4096)
	_, d := decode_speed_tree_body(data, 0, len(data))
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect(t, len(d.items) > 0 && d.items[0].code == "ue3.bad-speedtree")
}
