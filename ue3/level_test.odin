package ue3

import "core:testing"
import "../diag"

build_level_payload :: proc() -> [dynamic]u8 {
	p := Builder{}
	put_i32(&p, 1) // NetIndex
	put_i32(&p, 0) // "None" tag
	put_i32(&p, 0)

	// Actors: TTransArray -> owner, count, references.
	put_i32(&p, 1) // owner = package index 1 (this Level)
	put_i32(&p, 2) // count
	put_i32(&p, 0) // null
	put_i32(&p, 1) // export 0 (the Level itself, for the class-name test)

	// FURL.
	put_fstring(&p, "unreal")
	put_fstring(&p, "")
	put_fstring(&p, "MyMap")
	put_fstring(&p, "")
	put_fstring(&p, "")
	put_i32(&p, 7777)
	put_i32(&p, 1)

	put_i32(&p, 0) // Model reference
	put_i32(&p, 0) // ModelComponents count
	put_i32(&p, 0) // GameSequences count
	// Rest of ULevel::Serialize for 576: empty streaming/physics/cover tables.
	put_i32(&p, 0) // TextureToInstancesMap
	put_i32(&p, 1) // CachedPhysBSPData element size
	put_i32(&p, 0) // CachedPhysBSPData count
	put_i32(&p, 0) // CachedPhysSMDataMap
	put_i32(&p, 0) // CachedPhysSMDataStore
	put_i32(&p, 0) // CachedPhysPerTriSMDataMap
	put_i32(&p, 0) // CachedPhysPerTriSMDataStore
	put_i32(&p, 0) // CachedPhysBSPDataVersion
	put_i32(&p, 0) // CachedPhysSMDataVersion
	put_i32(&p, 0) // ForceStreamTextures
	put_i32(&p, 0) // NavListStart
	put_i32(&p, 0) // NavListEnd
	put_i32(&p, 0) // CoverListStart
	put_i32(&p, 0) // CoverListEnd
	put_i32(&p, 0) // CrossLevelActors
	return p.buf
}

build_single_level_package :: proc(payload: []u8) -> [dynamic]u8 {
	names_buf: [dynamic]u8
	nb := Builder{buf = names_buf}
	for text in ([]string{"None", "Class", "Package", "Engine", "Level", "PersistentLevel"}) {
		put_name_entry(&nb, text, 0)
	}
	names_buf = nb.buf

	imports_buf: [dynamic]u8
	ib := Builder{buf = imports_buf}
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, 0)
	put_name_ref(&ib, 3, 0)
	put_name_ref(&ib, 2, 0)
	put_name_ref(&ib, 1, 0)
	put_i32(&ib, -1)
	put_name_ref(&ib, 4, 0)
	imports_buf = ib.buf

	header_fixed := 4 + 4 + 4 + 4 + 4 + 28 + 16 + 4 + 12 + 4 + 4 + 4 + 4 + 4 + 4
	import_offset := header_fixed + len(names_buf)
	export_offset := import_offset + len(imports_buf)
	payload_offset := export_offset + 68
	depends_offset := payload_offset + len(payload)

	exports_buf: [dynamic]u8
	eb := Builder{buf = exports_buf}
	put_i32(&eb, -2) // class = import 1 (Level)
	put_i32(&eb, 0)
	put_i32(&eb, 0)
	put_name_ref(&eb, 5, 0)
	put_i32(&eb, 0)
	put_u64(&eb, 0)
	put_i32(&eb, i32(len(payload)))
	put_i32(&eb, i32(payload_offset))
	put_u32(&eb, 0)
	put_i32(&eb, 0)
	put_guid(&eb)
	put_u32(&eb, 0)
	exports_buf = eb.buf

	out: [dynamic]u8
	h := Builder{buf = out}
	put_u32(&h, PACKAGE_FILE_TAG)
	put_u32(&h, 0x00050240)
	put_i32(&h, i32(header_fixed))
	put_fstring(&h, "")
	put_u32(&h, PKG_COOKED)
	put_i32(&h, 6)
	put_i32(&h, i32(header_fixed))
	put_i32(&h, 1)
	put_i32(&h, i32(export_offset))
	put_i32(&h, 2)
	put_i32(&h, i32(import_offset))
	put_i32(&h, i32(depends_offset))
	put_guid(&h)
	put_i32(&h, 1)
	put_i32(&h, 1)
	put_i32(&h, 6)
	put_i32(&h, 0)
	put_i32(&h, 4701)
	put_i32(&h, 87)
	put_u32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	put_i32(&h, 0)
	append(&h.buf, ..names_buf[:])
	append(&h.buf, ..imports_buf[:])
	append(&h.buf, ..exports_buf[:])
	append(&h.buf, ..payload)
	return h.buf
}

@(test)
test_read_level_actors_and_url :: proc(t: ^testing.T) {
	payload := build_level_payload()
	data := build_single_level_package(payload[:])
	pkg, d := parse(data[:])
	defer delete(d.items)
	testing.expect_value(t, diag.count(&d, .Error), 0)

	level, l_diags := read_level(&pkg, 0)
	defer delete(l_diags.items)
	testing.expect_value(t, diag.count(&l_diags, .Error), 0)
	testing.expect_value(t, level.actors_owner, i32(1))
	testing.expect_value(t, len(level.actors), 2)
	testing.expect_value(t, level.actors[0], i32(0))
	testing.expect_value(t, level.url.protocol, "unreal")
	testing.expect_value(t, level.url.map_name, "MyMap")
	testing.expect_value(t, level.url.port, i32(7777))
	testing.expect(t, level.url.valid)
	testing.expect_value(t, level.model_index, i32(0))
	testing.expect_value(t, len(level.model_components), 0)
	testing.expect_value(t, level.game_sequences_count, i32(0))

	// The second reference points at the Level export itself.
	testing.expect_value(t, actor_class_name(&pkg, level.actors[1]), "Level")
	testing.expect_value(t, actor_class_name(&pkg, 0), "")
}
