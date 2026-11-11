package main

import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"

// Verification is a claim about bytes, so the falsifier is a file that lies: an archive
// whose tree says one CRC32 and whose payload has another. The fixture is the smallest
// version 2 VPK the reader accepts: one entry, stored inside the directory file.

verify_put_u32 :: proc(data: []u8, at: int, value: u32) {
	data[at + 0] = u8(value)
	data[at + 1] = u8(value >> 8)
	data[at + 2] = u8(value >> 16)
	data[at + 3] = u8(value >> 24)
}

verify_put_u16 :: proc(data: []u8, at: int, value: u16) {
	data[at + 0] = u8(value)
	data[at + 1] = u8(value >> 8)
}

// build_vpk writes a one entry archive. `crc` is what the tree claims; the payload is
// always "hello", so a caller passes either its real CRC32 or a wrong one.
build_vpk :: proc(crc: u32) -> []u8 {
	tree_size := 4 + 2 + 2 + 18 + 3
	data := make([]u8, 28 + tree_size + 5)
	verify_put_u32(data, 0, 0x55AA1234)
	verify_put_u32(data, 4, 2)
	verify_put_u32(data, 8, u32(tree_size))
	at := 28
	copy(data[at:], "txt\x00")
	at += 4
	copy(data[at:], "a\x00")
	at += 2
	copy(data[at:], "b\x00")
	at += 2
	verify_put_u32(data, at + 0, crc)
	verify_put_u16(data, at + 4, 0) // no preload
	verify_put_u16(data, at + 6, 0x7FFF) // stored inside this file
	verify_put_u32(data, at + 8, 0) // offset from the end of the tree
	verify_put_u32(data, at + 12, 5) // length
	verify_put_u16(data, at + 16, 0xFFFF)
	at += 18
	// The three empty names: the file list, the directory list and the extension list.
	data[at + 0] = 0
	data[at + 1] = 0
	data[at + 2] = 0
	copy(data[28 + tree_size:], "hello")
	return data
}

// The tests write a file each, under their own name: Odin runs tests concurrently and a
// shared name would let one test read the other's archive.
write_vpk_fixture :: proc(t: ^testing.T, name: string, crc: u32) -> bool {
	data := build_vpk(crc)
	defer delete(data)
	write_err := os.write_entire_file(name, data)
	testing.expectf(t, write_err == nil, "cannot write the fixture: %v", write_err)
	return write_err == nil
}

@(test)
test_a_vpk_whose_crc_matches_verifies :: proc(t: ^testing.T) {
	if !write_vpk_fixture(t, "test_verify_ok_dir.vpk", hash.crc32(transmute([]u8)string("hello"))) {
		return
	}
	defer os.remove("test_verify_ok_dir.vpk")

	report := verify_vpk("test_verify_ok_dir.vpk")
	defer delete(report.detail)
	testing.expect_value(t, report.entries, 1)
	testing.expect_value(t, report.verified, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.bytes, i64(5))
}

@(test)
test_a_vpk_whose_crc_lies_is_refused :: proc(t: ^testing.T) {
	if !write_vpk_fixture(t, "test_verify_lie_dir.vpk", 0xDEADBEEF) {
		return
	}
	defer os.remove("test_verify_lie_dir.vpk")

	report := verify_vpk("test_verify_lie_dir.vpk")
	defer delete(report.detail)
	testing.expect_value(t, report.verified, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expectf(t, strings.contains(report.detail, "CRC32"),
		"the detail does not name the checksum: %q", report.detail)
}

@(test)
test_a_file_this_build_cannot_verify_is_not_called_verified :: proc(t: ^testing.T) {
	_, ok := verify_one("something.txt")
	testing.expect(t, !ok, "a text file has no verifier and must not be reported as checked")

	report, bsp_ok := verify_one("a_map_without_pakfile.bsp")
	// Nothing to read means nothing to claim: the report says so instead of passing.
	testing.expect(t, bsp_ok)
	testing.expect_value(t, report.verified, 0)
	delete(report.detail)
}

@(test)
test_the_verify_report_names_what_it_counted :: proc(t: ^testing.T) {
	report := Verify_Report{kind = "vpk", entries = 3, bytes = 9, verified = 2, failed = 1, skipped = 1}
	text := verify_report_text(&report)
	defer delete(text)
	testing.expect(t, strings.contains(text, "3 entry/entries"))
	testing.expect(t, strings.contains(text, "2 verified"))
	testing.expect(t, strings.contains(text, "1 failed"))
	testing.expect(t, strings.contains(text, "1 not checkable"))
}
