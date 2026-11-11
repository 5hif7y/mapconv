package ue3

import "core:testing"
import "../diag"

// The convex caches of UBrushComponent and URB_BodySetup are counted byte blobs whose
// content is a PhysX cooked mesh. The payload is not decoded, but it is not taken on
// faith either: every element opens with the PhysX quick-load header. These tests break
// that header in each way a drifted walk would.

// build_convex_cache frames one set with one element of `body` bytes.
build_convex_cache :: proc(body: []u8) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, 12 + len(body))
	put_i32_buf(&out, 1) // one set
	put_i32_buf(&out, 1) // one element
	put_i32_buf(&out, i32(len(body)))
	append(&out, ..body)
	return out
}

// physx_body builds an element body: {size, 0, chunks}, then the stream magic and zeros.
physx_body :: proc(total: int, chunk_count: i32 = PHYSX_CHUNKS, zero: i32 = 0) -> [dynamic]u8 {
	body := make([dynamic]u8, 0, total)
	put_i32_buf(&body, i32(total - 4))
	put_i32_buf(&body, zero)
	put_i32_buf(&body, chunk_count)
	append(&body, u8('N'), u8('X'), u8('S'), u8(0x01))
	for len(body) < total {
		append(&body, 0)
	}
	return body
}

run_convex_cache :: proc(data: []u8) -> (Brush_Component, diag.Diagnostics) {
	r := Reader{data = data, pos = 0, limit = len(data)}
	result: Brush_Component
	d := diag.init()
	_, _, _, _ = walk_cached_convex_sets(&r, &d, "test")
	return result, d
}

@(test)
test_a_convex_cache_with_a_physx_header_walks :: proc(t: ^testing.T) {
	body := physx_body(64)
	defer delete(body)
	data := build_convex_cache(body[:])
	defer delete(data)
	_, d := run_convex_cache(data[:])
	defer delete(d.items)
	testing.expect(t, !diag.has_errors(&d), "a blob that opens with the PhysX stream must walk")
}

@(test)
test_an_element_without_the_stream_magic_fails :: proc(t: ^testing.T) {
	body := physx_body(64)
	defer delete(body)
	body[12] = 'Z'
	data := build_convex_cache(body[:])
	defer delete(data)
	_, d := run_convex_cache(data[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].code, "ue3.physx-magic")
}

@(test)
test_a_quick_load_header_with_another_chunk_count_fails :: proc(t: ^testing.T) {
	body := physx_body(64, 3)
	defer delete(body)
	data := build_convex_cache(body[:])
	defer delete(data)
	_, d := run_convex_cache(data[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].code, "ue3.physx-header")
}

@(test)
test_a_quick_load_header_whose_zero_word_is_not_zero_fails :: proc(t: ^testing.T) {
	body := physx_body(64, PHYSX_CHUNKS, 7)
	defer delete(body)
	data := build_convex_cache(body[:])
	defer delete(data)
	_, d := run_convex_cache(data[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].code, "ue3.physx-header")
}

@(test)
test_an_element_that_overruns_its_export_fails :: proc(t: ^testing.T) {
	body := physx_body(64)
	defer delete(body)
	data := build_convex_cache(body[:])
	defer delete(data)
	// Claim two more elements than the bytes hold.
	data[4] = 3
	_, d := run_convex_cache(data[:])
	defer delete(d.items)
	testing.expect(t, diag.has_errors(&d))
	testing.expect_value(t, d.items[0].code, "ue3.bad-cached-phys")
}
