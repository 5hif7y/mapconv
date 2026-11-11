package main

// Verification is the part of the toolkit that answers one question with an exit code:
// are the bytes still the bytes the file says they are?
//
// Nothing here interprets a format. A VPK tree records a CRC32 for every entry and a BSP
// pakfile is a ZIP directory that does the same, so the check is the file's own claim
// against the file's own content. That is the reason it can be trusted to gate something:
// a reader can be wrong and still consistent with itself, but a CRC cannot.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "bsp"
import "diag"
import "vpk"

Verify_Report :: struct {
	path:      string,
	kind:      string,
	entries:   int,
	bytes:     i64,
	verified:  int,
	failed:    int,
	detail:    string,
	// skipped counts entries this build cannot check: a preloaded VPK entry lives in
	// the tree and the reader does not splice it, so it is refused rather than passed.
	skipped:   int,
}

verify_report_text :: proc(report: ^Verify_Report) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s: %d entry/entries, %d bytes, %d verified, %d failed",
		report.kind, report.entries, report.bytes, report.verified, report.failed)
	if report.skipped > 0 {
		fmt.sbprintf(&b, ", %d not checkable", report.skipped)
	}
	if report.detail != "" {
		fmt.sbprintf(&b, " — %s", report.detail)
	}
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

VPK_SIGNATURE :: 0x55AA1234

// vpk_signature reads the first four bytes of a file, which is all it takes to tell a
// directory file from a payload shard: a game ships one tree and many shards, and a shard
// claims nothing that could be checked on its own.
vpk_signature :: proc(path: string) -> (signature: u32, ok: bool) {
	handle, open_err := os.open(path)
	if open_err != nil {
		return 0, false
	}
	defer os.close(handle)
	buffer: [4]u8
	read, read_err := os.read(handle, buffer[:])
	if read_err != nil || read != 4 {
		return 0, false
	}
	return u32(buffer[0]) | u32(buffer[1]) << 8 | u32(buffer[2]) << 16 | u32(buffer[3]) << 24, true
}

// verify_vpk reads every entry of an archive through the VPK tree, which computes the
// CRC32 of what it read: an entry that is short, unreadable or wrong fails here and not
// in a conversion three steps later.
verify_vpk :: proc(path: string) -> Verify_Report {
	report := Verify_Report{path = path, kind = "vpk"}
	tree, d := vpk.parse(path)
	defer vpk.destroy(&tree)
	if diag.has_errors(&d) {
		for item in d.items {
			if item.severity == .Error && report.detail == "" {
				report.detail = fmt.aprintf("%s: %s", item.code, item.message)
			}
		}
		if report.detail == "" {
			report.detail = strings.clone(diag.summary(&d))
		}
		report.failed = 1
		delete(d.items)
		return report
	}
	report.entries = len(tree.entries)
	first_failure: string
	for entry in tree.entries {
		payload, ok, entry_diagnostics := vpk.read_entry(&tree, entry)
		defer delete(entry_diagnostics.items)
		if ok {
			report.verified += 1
			report.bytes += i64(len(payload))
			delete(payload)
			continue
		}
		if diag.has_warnings(&entry_diagnostics) && !diag.has_errors(&entry_diagnostics) {
			// A preloaded entry cannot be checked by this reader; counting it as
			// verified would be a claim, so it is counted on its own.
			report.skipped += 1
			continue
		}
		report.failed += 1
		if first_failure == "" {
			// The message, not the count: a failure has to say which entry lied and
			// how, or the exit code is all anybody has.
			for item in entry_diagnostics.items {
				if item.severity == .Error && item.message != "" {
					first_failure = fmt.aprintf("%s: %s", item.code, item.message)
					break
				}
			}
			if first_failure == "" {
				first_failure = strings.clone(diag.summary(&entry_diagnostics))
			}
		}
	}
	report.detail = first_failure
	return report
}

// verify_bsp checks the pakfile lump: the archive tiles the lump and every entry's CRC32
// matches the directory. The other lumps are a reader's business, not a checksum's.
verify_bsp :: proc(path: string, data: []u8) -> Verify_Report {
	report := Verify_Report{path = path, kind = "bsp pakfile"}
	offset := bsp.lump_int(data, bsp.LUMP_PAKFILE, 0)
	length := bsp.lump_int(data, bsp.LUMP_PAKFILE, 4)
	if offset <= 0 || length <= 0 {
		report.detail = strings.clone("the map carries no pakfile")
		return report
	}
	pak := bsp.verify_pakfile(data, offset, length)
	if pak.reason != "" {
		report.detail = strings.clone(pak.reason)
		report.failed = 1
		return report
	}
	report.entries = pak.entries
	report.bytes = pak.payload
	report.verified = pak.verified
	report.failed = pak.entries - pak.verified
	return report
}

// run_verify answers with exit code 0 when every claim held, 1 when one did not and 2
// when it was asked about a file it cannot check.
run_verify :: proc(args: Args) {
	paths := make([dynamic]string, 0, 8, context.allocator)
	defer {
		for p in paths {
			delete(p)
		}
		delete(paths)
	}
	if args.corpus != "" {
		walk_verifiable(args.corpus, &paths)
	} else {
		append(&paths, strings.clone(args.input))
	}
	if len(paths) == 0 {
		fmt.eprintln("verify: nothing to check")
		os.exit(2)
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	failed := 0
	unsupported := 0
	entries := 0
	verified := 0
	shards := 0
	for path in paths {
		report, ok := verify_one(path)
		if !ok {
			unsupported += 1
			fmt.sbprintfln(&b, "%s: no verifier for this format", filepath.base(path))
			continue
		}
		fmt.sbprintf(&b, "%s: ", filepath.base(path))
		fmt.sbprintf(&b, "%s", verify_report_text(&report))
		if report.failed > 0 {
			failed += 1
		}
		if report.kind == "vpk shard" {
			shards += 1
		}
		entries += report.entries
		verified += report.verified
		delete(report.detail)
	}
	if len(paths) > 1 {
		fmt.sbprintfln(&b, "total: %d file(s), %d entry/entries, %d verified, %d failed, %d payload shard(s) not checkable on their own",
			len(paths) - unsupported, entries, verified, failed, shards)
	}
	if !args.quiet {
		fmt.print(strings.to_string(b))
	}
	if failed > 0 {
		fmt.eprintfln("verify: %d file(s) failed", failed)
		os.exit(1)
	}
	if unsupported > 0 && len(paths) == unsupported {
		os.exit(2)
	}
}

verify_one :: proc(path: string) -> (report: Verify_Report, ok: bool) {
	if strings.has_suffix(path, ".vpk") || strings.has_suffix(path, ".VPK") {
		signature, read_ok := vpk_signature(path)
		if read_ok && signature != VPK_SIGNATURE {
			if strings.contains(filepath.base(path), "_dir") {
				// A directory file has to be a directory file: this one is not, and
				// that is the failure, not a shard mistaken for a tree.
				return Verify_Report {
					path = path,
					kind = "vpk",
					failed = 1,
					detail = fmt.aprintf("a directory file without the VPK signature (0x%08X)", signature),
				}, true
			}
			result := Verify_Report {
				path = path,
				kind = "vpk shard",
				skipped = 1,
				detail = strings.clone("a payload shard: its entries are checked by the directory file"),
			}
			return result, true
		}
		return verify_vpk(path), true
	}
	if strings.has_suffix(path, ".bsp") || strings.has_suffix(path, ".BSP") {
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			return Verify_Report{path = path, kind = "bsp", failed = 1, detail = strings.clone("the file could not be read")}, true
		}
		defer delete(data)
		return verify_bsp(path, data), true
	}
	return report, false
}

// walk_verifiable collects the files a verifier owns, so one command can check a tree of
// archives without a shell loop keeping the list.
walk_verifiable :: proc(dir: string, out: ^[dynamic]string) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintln("verify: cannot read", dir)
		return
	}
	defer delete(entries)
	for entry in entries {
		if entry.name == "." || entry.name == ".." {
			continue
		}
		path := fmt.aprintf("%s/%s", dir, entry.name)
		if entry.type == .Directory {
			walk_verifiable(path, out)
			delete(path)
			continue
		}
		extension := filepath.ext(path)
		switch extension {
		case ".vpk", ".VPK", ".bsp", ".BSP":
			append(out, path)
		case:
			delete(path)
		}
	}
}
