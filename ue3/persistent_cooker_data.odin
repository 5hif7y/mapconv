package ue3

import "core:fmt"
import "core:math"
import "core:strings"
import "../diag"

// UPersistentCookerData (UnrealEd/Src/UnContentCookers.cpp:14918) keeps the
// cooker's bookkeeping: which bulk data blocks were written, where, and when the
// source files were cooked. The class is editor-only, so the shipped layout of
// build 4701 differs from the tree's source; this reader follows the measurement
// on the corpus (GlobalPersistentCookerData.ccpk, one object, 7.590.999 bytes):
//
//	bulk data infos   count, then per entry FString key + FCookedBulkDataInfo
//	file times        count, then per entry FString + DOUBLE (unix seconds)
//	cache waste       QWORD
//	last cook time    DOUBLE
//	cooked versions   count, then per entry FString + INT
//	texture formats   DWORD
//
// FCookedBulkDataInfo (UnrealEd/Inc/UnContentCookers.h:15) is 24 bytes: flags,
// element count, offset, size on disk and the texture cache FName. Offsets and
// sizes use INDEX_NONE (-1) when the block was not stored, so -1 is valid in all
// four numeric fields; any other negative value is a layout error.
Persistent_Cooker_Data :: struct {
	bulk_infos:      int,
	file_times:      int,
	cooked_versions: int,
	waste:           u64,
	formats:         u32,
}

read_persistent_cooker_data :: proc(
	pkg: ^Package,
	export_index: int,
	allocator := context.allocator,
) -> (result: Persistent_Cooker_Data, d: diag.Diagnostics) {
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
	fail :: proc(d: ^diag.Diagnostics, what: string) {
		diag.err(d, "ue3.persistent-cooker", what)
	}

	// Bulk data infos.
	infos := read_i32(&r)
	if r.failed || infos < 0 || i64(infos) * 12 > i64(r.limit - r.pos) {
		fail(&d, "implausible bulk data info count")
		return
	}
	// Every key names a bulk block, and a block is written once: no two entries may
	// carry the same key, and every key has to look like a path. Over the corpus the
	// single object of this class has 90,463 entries, 0 repeated and 0 without a
	// separator, which is what makes this a check of the walk and not a count of it.
	keys := make(map[string]bool, int(infos), context.allocator)
	defer {
		for key in keys {
			delete(key)
		}
		delete(keys)
	}
	for _ in 0 ..< int(infos) {
		key := read_fstring(&r)
		if !r.failed && key != "" {
			if key in keys {
				fail(&d, "a bulk data key appears twice")
				return
			}
			if !strings.contains_rune(key, '/') && !strings.contains_rune(key, '.') {
				fail(&d, "a bulk data key is not a path")
				return
			}
			keys[strings.clone(key, context.allocator)] = true
		}
		_ = read_i32(&r) // SavedBulkDataFlags
		elements := read_i32(&r)
		_ = read_i32(&r) // offset, INDEX_NONE allowed
		_ = read_i32(&r) // size on disk, INDEX_NONE allowed
		name_index := read_i32(&r)
		_ = read_i32(&r) // FName number
		if r.failed {
			fail(&d, "bulk data info ran past the export")
			return
		}
		if elements < -1 {
			fail(&d, "negative bulk element count")
			return
		}
		if name_index < -1 || int(name_index) > len(pkg.names) {
			fail(&d, fmt.aprintf("texture cache name index %d out of range", name_index))
			return
		}
	}
	if r.pos + 4 > r.limit {
		fail(&d, "missing file time count")
		return
	}
	result.bulk_infos = int(infos)

	// File times.
	times := read_i32(&r)
	if r.failed || times < 0 || i64(times) * 12 > i64(r.limit - r.pos) {
		fail(&d, "implausible file time count")
		return
	}
	for _ in 0 ..< int(times) {
		_ = read_fstring(&r)
		stamp := read_f64(&r)
		if r.failed || math.is_nan(stamp) || math.is_inf(stamp) || stamp < 0 || stamp > 1e10 {
			fail(&d, "file time is not a plausible timestamp")
			return
		}
	}
	result.file_times = int(times)
	result.waste = read_u64(&r)

	// Last cook time.
	stamp := read_f64(&r)
	if r.failed || math.is_nan(stamp) || math.is_inf(stamp) || stamp < 0 || stamp > 1e10 {
		fail(&d, "cook time is not a plausible timestamp")
		return
	}

	// Cooked versions.
	versions := read_i32(&r)
	if r.failed || versions < 0 || i64(versions) * 16 > i64(r.limit - r.pos) {
		fail(&d, "implausible cooked version count")
		return
	}
	for _ in 0 ..< int(versions) {
		_ = read_fstring(&r)
		version := read_i32(&r)
		if r.failed || version < 0 || version > 1_000_000 {
			fail(&d, "implausible cooked version")
			return
		}
	}
	result.cooked_versions = int(versions)
	result.formats = read_u32(&r)
	if r.failed {
		fail(&d, "missing texture formats word")
		return
	}
	if r.pos != head.end_offset {
		diag.err(&d, "ue3.persistent-cooker-layout", fmt.aprintf("UPersistentCookerData consumed %d of %d bytes", r.pos - head.body_offset, head.end_offset - head.body_offset))
		return
	}
	return
}
