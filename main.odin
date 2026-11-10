// mapconv is a multi-format, bidirectional map conversion toolkit.
//
// Commands:
//   mapconv convert  --input <file> --output <file> [options]
//   mapconv inspect  --input <file>
//   mapconv validate --input <file>
//   mapconv extract  --input <file.ccmap> --output <dir>   (DDS + OBJ)
//   mapconv audit    --input <file>                        byte coverage
//
// Exit codes: 0 success, 1 the conversion produced errors, 2 usage or I/O error.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "bsp"
import "convert"
import "diag"
import "ir"
import "ue3"
import "vtf"
import "xform"

VERSION :: "0.1.0"

USAGE :: `mapconv — multi-format map conversion toolkit

Usage:
  mapconv convert  --input <file> --output <file> [options]
  mapconv inspect  --input <file> [--from <format>]
  mapconv validate --input <file> [--from <format>]
  mapconv extract  --input <file.ccmap|ccpk> --output <dir>   DDS textures + OBJ meshes
  mapconv audit    --input <file>                              byte coverage by class
  mapconv --version

Options:
  --input <file>       map to read
  --output <file>      map to write (convert only)
  --from <format>      override the input format: vmf, bsp, t3d, ccmap
  --to <format>        override the output format: vmf, t3d
  --profile <name>     entity mapping profile (default, source1-to-unreal3,
                       unreal3-to-source1)
  --report <file>      write the diagnostic report to a file as well as stderr
  --content <dir>      cooked content directory used to resolve mesh imports
  --quiet              only print errors
  --no-materials       skip the per-material notes

Supported formats:
  vmf   Source 1 Valve Map Format (text)
  bsp   Source 1 compiled map (import only)
  t3d   Unreal Engine 3 T3D text interchange
  ccmap Unreal Engine 3 cooked package (inspect/validate only for now)

Bidirectional support is implemented for both; conversion is not lossless and
every approximation is reported as a diagnostic.
`

Args :: struct {
	command:  string,
	input:    string,
	output:   string,
	from:     ir.Format,
	to:       ir.Format,
	profile:  string,
	report:   string,
	content:  string,
	quiet:    bool,
	objects:  bool,
	dump:     bool,
	materials: bool,
	ok:       bool,
}

main :: proc() {
	args, ok := parse_args(os.args[1:])
	if !ok {
		os.exit(2)
	}

	if args.command == "version" {
		fmt.printfln("mapconv %s", VERSION)
		return
	}

	contents, read_err := os.read_entire_file(args.input, context.allocator)
	if read_err != nil {
		fmt.eprintfln("mapconv: cannot read %q", args.input)
		os.exit(2)
	}
	text := string(contents)

	switch args.command {
	case "convert":
		run_convert(args, text)
	case "inspect":
		run_inspect(args, text)
	case "validate":
		run_validate(args, text)
	case "extract":
		run_extract(args, text)
	case "audit":
		run_audit(args, text)
	case:
		fmt.eprintln(USAGE)
		os.exit(2)
	}
}

parse_args :: proc(argv: []string) -> (args: Args, ok: bool) {
	args.materials = true
	if len(argv) == 0 {
		fmt.eprintln(USAGE)
		return args, false
	}
	args.command = argv[0]
	if args.command == "--version" || args.command == "-v" || args.command == "version" {
		args.command = "version"
		return args, true
	}
	if args.command == "--help" || args.command == "-h" || args.command == "help" {
		fmt.println(USAGE)
		return args, false
	}
	i := 1
	for i < len(argv) {
		flag := argv[i]
		need_value := proc(flag: string) -> bool {
			switch flag {
			case "--input", "--output", "--from", "--to", "--profile", "--report", "--content":
				return true
			}
			return false
		}
		if need_value(flag) {
			if i + 1 >= len(argv) {
				fmt.eprintfln("mapconv: %s needs a value", flag)
				return args, false
			}
			value := argv[i + 1]
			i += 2
			switch flag {
			case "--input":
				args.input = value
			case "--output":
				args.output = value
			case "--from":
				format, format_ok := parse_format(value)
				if !format_ok {
					fmt.eprintfln("mapconv: unknown format %q", value)
					return args, false
				}
				args.from = format
			case "--to":
				format, format_ok := parse_format(value)
				if !format_ok {
					fmt.eprintfln("mapconv: unknown format %q", value)
					return args, false
				}
				args.to = format
			case "--profile":
				args.profile = value
			case "--report":
				args.report = value
			case "--content":
				args.content = value
			}
			continue
		}
		switch flag {
		case "--objects":
			args.objects = true
		case "--dump":
			args.dump = true
		case "--quiet":
			args.quiet = true
		case "--no-materials":
			args.materials = false
		case:
			fmt.eprintfln("mapconv: unknown option %q", flag)
			fmt.eprintln(USAGE)
			return args, false
		}
		i += 1
	}
	if args.input == "" {
		fmt.eprintln("mapconv: --input is required")
		return args, false
	}
	if args.command == "convert" && args.output == "" {
		fmt.eprintln("mapconv: --output is required for convert")
		return args, false
	}
	if args.command == "extract" && args.output == "" {
		fmt.eprintln("mapconv: --output is required for extract")
		return args, false
	}
	return args, true
}

parse_format :: proc(text: string) -> (format: ir.Format, ok: bool) {
	switch strings.to_lower(text) {
	case "auto", "":
		return .Unknown, true
	case "vmf", "source", "source1":
		return .Source_VMF, true
	case "bsp", "source-bsp":
		return .Source_BSP, true
	case "t3d", "unreal", "unreal3", "ue3":
		return .Unreal_T3D, true
	}
	return .Unknown, false
}

run_convert :: proc(args: Args, text: string) {
	target := args.to
	if target == .Unknown {
		target = convert.format_from_extension(args.output)
	}
	if target == .Unknown {
		fmt.eprintfln("mapconv: cannot tell the output format from %q; pass --to vmf|t3d", args.output)
		os.exit(2)
	}

	source := args.from
	if source == .Unknown {
		source, _ = convert.detect_format(args.input, text)
	}
	if target == .UE3_Package {
		fmt.eprintln("mapconv: UE3 packages are not an output format; write a .t3d for UnrealEd instead")
		os.exit(2)
	}

	options := convert.Options {
		from             = args.from,
		to               = target,
		profile_name     = args.profile,
		keep_source_ids  = true,
		report_materials = args.materials,
	}
	result := convert.convert_text(text, args.input, options)

	if !args.quiet {
		fmt.print(convert.inspect_document(&result.doc))
		fmt.printfln("")
	}
	print_diagnostics(&result.diagnostics, args.quiet, args.report)

	if !result.ok {
		fmt.eprintln("mapconv: conversion failed; no output written")
		os.exit(1)
	}
	if os.write_entire_file(args.output, result.output) != nil {
		fmt.eprintfln("mapconv: cannot write %q", args.output)
		os.exit(2)
	}
	fmt.printfln("wrote %s (%d bytes)", args.output, len(result.output))
}

run_inspect :: proc(args: Args, text: string) {
	format := args.from
	if format == .Unknown {
		detected, _ := convert.detect_format(args.input, text)
		format = detected
	}
	if format == .UE3_Package {
		inspect_package(text, args.input, args.quiet, args.report)
		return
	}
	doc, diagnostics := import_only(text, args.input, format)
	if diag.has_errors(&diagnostics) {
		print_diagnostics(&diagnostics, args.quiet, args.report)
		os.exit(1)
	}
	fmt.print(convert.inspect_document(&doc))
	fmt.printfln("diagnostics: %s", diag.summary(&diagnostics))
	if !args.quiet {
		print_diagnostics(&diagnostics, args.quiet, args.report)
	}
}

run_validate :: proc(args: Args, text: string) {
	format := args.from
	if format == .Unknown {
		detected, _ := convert.detect_format(args.input, text)
		format = detected
	}
	if format == .UE3_Package {
		validate_package(text, args.input, args.report)
		return
	}
	doc, diagnostics := import_only(text, args.input, format)
	convert.validate_document(&doc, &diagnostics)
	print_diagnostics(&diagnostics, false, args.report)
	if diag.has_errors(&diagnostics) {
		fmt.eprintfln("mapconv: validation failed: %s", diag.summary(&diagnostics))
		os.exit(1)
	}
	fmt.printfln("ok: %s", diag.summary(&diagnostics))
}

// run_extract_bsp writes the pakfile entries of a Source BSP (lump 40), which
// holds the VTF/VMT assets the map carries for itself.
run_extract_bsp :: proc(args: Args, text: string) {
	data := transmute([]u8)text
	diagnostics := diag.init()
	file, _ := bsp.read(data, &diagnostics, args.input)
	if diag.has_errors(&diagnostics) {
		print_diagnostics(&diagnostics, args.quiet, args.report)
		os.exit(1)
	}
	if err := os.make_directory_all(args.output); err != nil {
		fmt.eprintfln("mapconv: cannot create %q", args.output)
		os.exit(2)
	}
	offset, length := file.header[bsp.LUMP_PAKFILE][0], file.header[bsp.LUMP_PAKFILE][1]
	// The archive is verified before a single file is written: the CRC32 of every
	// entry is checked against the directory and the records have to tile the lump.
	// Writing the assets of a damaged archive would put wrong textures on a map.
	if length > 0 {
		report := bsp.verify_pakfile(data, offset, length)
		if report.reason != "" {
			fmt.eprintfln("mapconv: the pakfile of %s does not verify: %s", args.input, report.reason)
			os.exit(1)
		}
	}
	entries, pak_d := bsp.read_pakfile(data, offset, length)
	merge_diags(&diagnostics, &pak_d)
	written := 0
	skipped := 0
	bytes := 0
	for entry in entries {
		payload, ok := bsp.pak_entry_data(data, entry)
		if !ok {
			skipped += 1
			continue
		}
		path := fmt.aprintf("%s/%s", args.output, entry.name)
		defer delete(path)
		dir := filepath.dir(path)
		if len(dir) > 0 {
			_ = os.make_directory_all(dir)
		}
		if os.write_entire_file(path, payload) != nil {
			fmt.eprintfln("mapconv: cannot write %q", path)
			os.exit(2)
		}
		written += 1
		bytes += len(payload)
		if entry.method == 8 {
			delete(payload)
		}
	}
	fmt.printfln("extracted %d of %d pakfile entr(ies), %d bytes (%d skipped)", written, len(entries), bytes, skipped)
	print_diagnostics(&diagnostics, args.quiet, args.report)
}

// run_audit reports how many bytes of a package the reader interprets.
run_audit :: proc(args: Args, text: string) {
	data := transmute([]u8)text
	if strings.has_suffix(args.input, ".bsp") || strings.has_suffix(args.input, ".BSP") {
		audit := bsp.audit_lumps(data)
		fmt.print(bsp.audit_lumps_text(&audit))
		bsp.audit_lumps_destroy(&audit)
		return
	}
	pkg, diagnostics := ue3.parse(data)
	if diag.has_errors(&diagnostics) {
		print_diagnostics(&diagnostics, args.quiet, args.report)
		os.exit(1)
	}
	audit, audit_d := ue3.audit_package(&pkg)
	fmt.print(ue3.audit_text(&audit))
	if args.objects {
		fmt.print(ue3.audit_objects_text(&audit))
	}
	if args.dump {
		fmt.print(ue3.audit_dump_text(&pkg))
	}
	print_diagnostics(&diagnostics, args.quiet, args.report)
	_ = audit_d
	delete(audit.rows)
	delete(audit.objects)
}

// merge_diags appends one diagnostic list to another and frees the source.
merge_diags :: proc(dst: ^diag.Diagnostics, src: ^diag.Diagnostics) {
	for item in src.items {
		append(&dst.items, item)
		dst.counts[int(item.severity)] += 1
	}
	delete(src.items)
}

// run_extract writes every readable texture of a UE3 package as a DDS file.
// Streamed mips (texture file cache) and unsupported formats are reported.

// write_texture_vtf emits a VTF next to the DDS using the largest inline run of
// mips. Full chains (an *_art package) produce full-resolution textures.

// resolve_missing_basetextures rewrites VMTs whose $basetexture has no VTF in the
// extracted set. UE3 materials can reference FX textures that live in packages
// the map does not pull in; pointing them at an existing texture keeps the
// surface textured instead of showing the engine's missing-material checker.
resolve_missing_basetextures :: proc(output: string) -> (rewritten: int) {
	entries, err := os.read_directory_by_path(output, -1, context.allocator)
	if err != nil {
		return 0
	}
	defer delete(entries)
	textures := make([dynamic]string, 0, 64)
	defer delete(textures)
	for e in entries {
		if !strings.has_suffix(strings.to_lower(e.name), ".vtf") {
			continue
		}
		stem := e.name[:len(e.name) - 4]
		if !ue3.is_diffuse_candidate(stem) {
			continue
		}
		append(&textures, stem)
	}
	if len(textures) == 0 {
		return 0
	}
	dir := fmt.aprintf("%s/materials/mapconv", output)
	defer delete(dir)
	mt, mt_err := os.read_directory_by_path(dir, -1, context.allocator)
	if mt_err != nil {
		return 0
	}
	defer delete(mt)
	for e in mt {
		name := e.name
		if !strings.has_suffix(strings.to_lower(name), ".vmt") {
			continue
		}
		path := fmt.aprintf("%s/%s", dir, name)
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			delete(path)
			continue
		}
		text := string(data)
		lines := strings.split(text, "\n")
		changed := false
		for line, i in lines {
			if !strings.contains(line, "\"$basetexture\"") {
				continue
			}
			// Skip the key token, then read the value token: line is
			//   "$basetexture" "<name>"
			first := strings.index(line, "\"")
			if first < 0 {
				continue
			}
			after_key := line[first+1:]
			key_end := strings.index(after_key, "\"")
			if key_end < 0 {
				continue
			}
			after := after_key[key_end+1:]
			value_start := strings.index(after, "\"")
			if value_start < 0 {
				continue
			}
			value_rest := after[value_start+1:]
			value_end := strings.index(value_rest, "\"")
			if value_end < 0 {
				continue
			}
			tex := value_rest[:value_end]
			probe := fmt.aprintf("%s/%s.vtf", output, tex)
			_, stat_err := os.stat(probe, context.allocator)
			delete(probe)
			if stat_err == nil {
				continue
			}
			// Pick the candidate that shares the most name tokens with the
			// material: the first entry of the directory is alphabetical and
			// used to be a channel-blend map, which painted every FX material
			// as a red/green/blue panel.
			best := textures[0]
			best_score := -1
			for candidate in textures {
				score := name_affinity(name, candidate)
				if score > best_score {
					best_score = score
					best = candidate
				}
			}
			lines[i] = fmt.aprintf("\t\"$basetexture\" \"%s\"", best)
			changed = true
			rewritten += 1
		}
		if changed {
			joined := strings.join(lines, "\n")
			_ = os.write_entire_file(path, transmute([]u8)joined)
			delete(joined)
		}
		delete(lines)
		delete(data)
		delete(path)
	}
	return rewritten
}

// name_affinity counts the lowercased "_"-separated tokens two names share.
name_affinity :: proc(a, b: string) -> int {
	la := strings.split(strings.to_lower(a), "_", context.temp_allocator)
	lb := strings.split(strings.to_lower(b), "_", context.temp_allocator)
	score := 0
	for x in la {
		for y in lb {
			if x == y && len(x) > 2 {
				score += 1
			}
		}
	}
	return score
}

mesh_transform :: proc() -> xform.Transform {
	t, _ := xform.transform_between(xform.unreal_3(), xform.source_1())
	return t
}

write_texture_vtf :: proc(texture: ^ue3.Texture, output, name: string) {
	first := 0
	for first < len(texture.mips) && len(texture.mips[first].data) == 0 {
		first += 1
	}
	if first >= len(texture.mips) {
		return
	}
	count := 0
	for mip in texture.mips[first:] {
		if len(mip.data) == 0 {
			break
		}
		count += 1
	}
	code: u32 = 0
	switch texture.format {
	case "PF_DXT1": code = vtf.IMAGE_FORMAT_DXT1
	case "PF_DXT3": code = vtf.IMAGE_FORMAT_DXT3
	case "PF_DXT5": code = vtf.IMAGE_FORMAT_DXT5
	case "PF_A8R8G8B8": code = vtf.IMAGE_FORMAT_BGRA8888
	}
	if code == 0 || count == 0 {
		return
	}
	// A texture whose larger mips are streamed but whose cache could not be
	// resolved has a run that does not match the dimensions of its first mip.
	// Emitting it anyway produces a VTF the engine rejects ("Error reading
	// texture data"). Walk forward until a suffix is self-consistent.
	run := make([][]u8, count)
	for start in first ..< len(texture.mips) {
		n := 0
		for mip in texture.mips[start:] {
			if len(mip.data) == 0 {
				break
			}
			n += 1
		}
		if n == 0 {
			break
		}
		w := int(texture.mips[start].width)
		h := int(texture.mips[start].height)
		expected := 0
		for k in 0 ..< n {
			mw := max(1, w >> uint(k))
			mh := max(1, h >> uint(k))
			switch code {
			case vtf.IMAGE_FORMAT_DXT1:
				expected += max(1, (mw + 3) / 4) * max(1, (mh + 3) / 4) * 8
			case vtf.IMAGE_FORMAT_DXT3, vtf.IMAGE_FORMAT_DXT5:
				expected += max(1, (mw + 3) / 4) * max(1, (mh + 3) / 4) * 16
			case:
				expected += mw * mh * 4
			}
		}
		actual := 0
		for mip in texture.mips[start:start+n] {
			actual += len(mip.data)
		}
		if actual != expected {
			continue
		}
		part := run[:n]
		for m, k in texture.mips[start:start+n] {
			part[k] = m.data
		}
		if encoded, ok := vtf.encode(w, h, code, part); ok {
			_ = os.write_entire_file(fmt.aprintf("%s/%s.vtf", output, name), encoded)
		}
		return
	}
}

run_extract :: proc(args: Args, text: string) {
	lower_input := strings.to_lower(args.input)
	if strings.has_suffix(lower_input, ".dds") {
		w, h, format, mips, ok := vtf.from_dds(transmute([]u8)text)
		if !ok {
			fmt.eprintfln("mapconv: cannot read %q as DDS (DXT1/3/5 only)", args.input)
			os.exit(1)
		}
		if err := os.make_directory_all(args.output); err != nil {
			fmt.eprintfln("mapconv: cannot create %q", args.output)
			os.exit(2)
		}
		encoded, enc_ok := vtf.encode(w, h, format, mips)
		if !enc_ok {
			fmt.eprintfln("mapconv: cannot encode %q as VTF", args.input)
			os.exit(1)
		}
		base := filepath.stem(args.input)
		path := fmt.aprintf("%s/%s.vtf", args.output, base)
		if os.write_entire_file(path, encoded) != nil {
			fmt.eprintfln("mapconv: cannot write %q", path)
			os.exit(2)
		}
		fmt.printfln("wrote %s (%dx%d, %d bytes)", path, w, h, len(encoded))
		return
	}
	if strings.has_suffix(lower_input, ".vtf") {
		diagnostics := diag.init()
		dds, format_name, ok := vtf.to_dds(transmute([]u8)text, &diagnostics)
		if !ok {
			print_diagnostics(&diagnostics, args.quiet, args.report)
			os.exit(1)
		}
		if err := os.make_directory_all(args.output); err != nil {
			fmt.eprintfln("mapconv: cannot create %q", args.output)
			os.exit(2)
		}
		base := filepath.stem(args.input)
		path := fmt.aprintf("%s/%s.dds", args.output, base)
		if os.write_entire_file(path, dds) != nil {
			fmt.eprintfln("mapconv: cannot write %q", path)
			os.exit(2)
		}
		fmt.printfln("wrote %s (%s, %d bytes)", path, format_name, len(dds))
		print_diagnostics(&diagnostics, args.quiet, args.report)
		return
	}
	format := args.from
	if format == .Unknown {
		detected, _ := convert.detect_format(args.input, text)
		format = detected
	}
	if format == .Source_BSP {
		run_extract_bsp(args, text)
		return
	}
	if format != .UE3_Package {
		fmt.eprintln("mapconv: extract supports UE3 packages (.ccmap/.ccpk) and Source BSPs")
		os.exit(2)
	}
	pkg, diagnostics := ue3.parse(transmute([]u8)text)
	if diag.has_errors(&diagnostics) {
		print_diagnostics(&diagnostics, args.quiet, args.report)
		os.exit(1)
	}
	if err := os.make_directory_all(args.output); err != nil {
		fmt.eprintfln("mapconv: cannot create %q", args.output)
		os.exit(2)
	}

	total := 0
	written := 0
	skipped := 0
	used_names := make(map[string]bool, 256)
	defer delete(used_names)
	meshes := 0
	obj_files := 0
	referenced_meshes := 0
	smd_files := 0
	qc_files := 0
	for e, i in pkg.exports {
		if ue3.export_class_name(&pkg, e) != "Texture2D" {
			continue
		}
		total += 1
		texture, texture_d := ue3.read_texture(&pkg, i)
		merge_diags(&diagnostics, &texture_d)
		bytes, ok := ue3.dds_bytes(&texture)
		if !ok {
			skipped += 1
			continue
		}
		name := ue3.name_text(&pkg, e.object_name)
		// Two exports may share a name (CrimeCraft.u has two Texture2D objects
		// called Black). Writing both to the same file mixed the pair on disk and
		// made the round-trip check compare the DDS of one against the VTF of the
		// other, so repeats get a stable suffix from the export index.
		if name in used_names {
			name = fmt.aprintf("%s_%d", name, i)
			if name in used_names {
				name = fmt.aprintf("%s_%d", name, i)
			}
		}
		used_names[name] = true
		path := fmt.aprintf("%s/%s.dds", args.output, name)
		if os.write_entire_file(path, bytes) != nil {
			fmt.eprintfln("mapconv: cannot write %q", path)
			os.exit(2)
		}
		written += 1
		write_texture_vtf(&texture, args.output, name)
	}
	// Sky and tool materials ship inside the game VPK, not in UE3 content. When
	// the package carries cubemap faces, publish them as a 2D skybox so the
	// worldspawn skyname resolves, and give the seal shell a real tool material.
	// The synthetic cubemap faces (128 px clouds) were stretched over the whole
	// sky and produced the purple gradients, so the worldspawn asks the game VPK
	// for a real 2D sky (sky_cs15_daylight01_hdr) instead of overriding it.
	// TOOLS/TOOLSSKYBOX and TOOLS/TOOLSNODRAW ship in the game VPK; overriding
	// them painted the seal shell with a cubemap face, so nothing is emitted.

	// Streamed mips live in the sibling <map>_art.ccpk. When it is available in
	// the content tree, re-extract those textures so the files carry the full
	// mip chain (decoded from the UE3 compressed bulk blocks).
	if args.content != "" {
		stem := filepath.stem(args.input)
		cand := fmt.aprintf("%s/Packages/Instance/%s_art.ccpk", args.content, stem)
		defer delete(cand)
		if data, err := os.read_entire_file(cand, context.allocator); err == nil {
			art, art_d := ue3.parse(data)
			if !diag.has_errors(&art_d) {
				for e, i in art.exports {
					if ue3.export_class_name(&art, e) != "Texture2D" {
						continue
					}
					tex, td := ue3.read_texture(&art, i)
					if diag.has_errors(&td) {
						continue
					}
					name := ue3.name_text(&art, e.object_name)
					if bytes, ok := ue3.dds_bytes(&tex); ok {
						_ = os.write_entire_file(fmt.aprintf("%s/%s.dds", args.output, name), bytes)
						write_texture_vtf(&tex, args.output, name)
					}
				}
			}
		}
	}

	// Referenced meshes: the map only stores imports; with --content, follow the
	// import chain to the content package, then write OBJ (every LOD), an SMD and
	// a QC for the LOD 0 so studiomdl can produce the .mdl the VMF references.
	if args.content != "" {
		index, index_d := ue3.content_index(args.content)
		merge_diags(&diagnostics, &index_d)
		seen := make([dynamic]string, 0, 8)
		defer delete(seen)
		for e, i in pkg.exports {
			if ue3.export_class_name(&pkg, e) != "Level" {
				continue
			}
			level, level_d := ue3.read_level(&pkg, i)
			merge_diags(&diagnostics, &level_d)
			if diag.has_errors(&level_d) {
				continue
			}
			for actor in level.actors {
				if ue3.package_index_kind(actor) != .Export {
					continue
				}
				info, info_d := ue3.read_actor_info(&pkg, int(actor) - 1)
				merge_diags(&diagnostics, &info_d)
				if diag.has_errors(&info_d) || info.mesh_import >= 0 || info.mesh_name == "" {
					continue
				}
				key := fmt.aprintf("%s/%s", info.mesh_package, info.mesh_name)
				already := false
				for previous in seen {
					if previous == key {
						already = true
						break
					}
				}
				if already {
					delete(key)
					continue
				}
				append(&seen, key)
				resolved, res_d := ue3.resolve_static_mesh(&pkg, info.mesh_import, &index)
				merge_diags(&diagnostics, &res_d)
				if diag.has_errors(&res_d) || len(resolved.mesh.lods) == 0 {
					if len(resolved.mesh.lods) > 0 {
						ue3.resolved_mesh_destroy(&resolved)
					}
					continue
				}
				package_dir := fmt.aprintf("%s/%s", args.output, info.mesh_package)
				defer delete(package_dir)
				_ = os.make_directory_all(package_dir)
				for lod_index in 0..<len(resolved.mesh.lods) {
					obj := ue3.static_mesh_obj(&resolved.mesh, lod_index, mesh_transform())
					path := fmt.aprintf("%s/%s_L%d.obj", package_dir, info.mesh_name, lod_index)
					if os.write_entire_file(path, obj) != nil {
						fmt.eprintfln("mapconv: cannot write %q", path)
						os.exit(2)
					}
					delete(path)
					delete(obj)
					obj_files += 1
				}
				smd := ue3.static_mesh_smd(&resolved.mesh, 0, mesh_transform())
				smd_path := fmt.aprintf("%s/%s_L0.smd", package_dir, info.mesh_name)
				if os.write_entire_file(smd_path, smd) == nil {
					smd_files += 1
				}
				delete(smd_path)
				delete(smd)
				model_path := fmt.aprintf("mapconv/%s/%s.mdl", info.mesh_package, info.mesh_name)
				qc := ue3.static_mesh_qc(model_path, fmt.aprintf("%s_L0.smd", info.mesh_name), "mapconv")
				qc_path := fmt.aprintf("%s/%s.qc", package_dir, info.mesh_name)
				if os.write_entire_file(qc_path, qc) == nil {
					qc_files += 1
				}
				delete(qc_path)
				delete(qc)
				delete(model_path)
				ue3.resolved_mesh_destroy(&resolved)
				referenced_meshes += 1
			}
		}
		ue3.content_index_destroy(&index)
	}

	material_files := 0
	material_infos := make([dynamic]ue3.Material_Texture, 0, 64)
	defer delete(material_infos)
	for e, i in pkg.exports {
		class := ue3.export_class_name(&pkg, e)
		if class != "Material" && class != "MaterialInstanceConstant" {
			continue
		}
		info, md := ue3.read_material_texture(&pkg, i)
		merge_diags(&diagnostics, &md)
		if !info.has_texture {
			continue
		}
		append(&material_infos, info)
		dir := fmt.aprintf("%s/materials/mapconv", args.output)
		_ = os.make_directory_all(dir)
		path := fmt.aprintf("%s/%s.vmt", dir, info.material_name)
		if os.write_entire_file(path, ue3.material_vmt(info)) == nil {
			material_files += 1
		}
	}

	// Brush faces name their material by the base material (for example
	// industrial_pr_Lantern03) while the instances are exported as
	// M_industrial_pr_lantern03_blue. Without an alias VMT the engine paints
	// the whole level with its magenta missing-material checker.
	alias_files := 0
	alias_dir := fmt.aprintf("%s/materials/mapconv", args.output)
	defer delete(alias_dir)
	for e, i in pkg.exports {
		if ue3.export_class_name(&pkg, e) != "Polys" {
			continue
		}
		names := ue3.poly_material_names(&pkg, i)
		defer delete(names)
		for name in names {
			vmt := fmt.aprintf("%s/%s.vmt", alias_dir, name)
			_, stat_err := os.stat(vmt, context.allocator)
			if stat_err == nil {
				delete(vmt)
				continue
			}
			best := -1
			best_score := -1
			for candidate, ci in material_infos {
				score := name_affinity(name, candidate.material_name)
				if score > best_score {
					best_score = score
					best = ci
				}
			}
			if best >= 0 {
				alias := ue3.Material_Texture {
					material_name = name,
					texture_name  = material_infos[best].texture_name,
					has_texture   = true,
					has_bump      = material_infos[best].has_bump,
					bump_name     = material_infos[best].bump_name,
				}
				if os.write_entire_file(vmt, ue3.material_vmt_for(name, alias)) == nil {
					alias_files += 1
				}
			}
			delete(vmt)
		}
	}

	// Static meshes embedded in the package: one OBJ per LOD, under a directory
	// named after the map, mirroring the "<package>/<mesh>.mdl" path the VMF
	// references after studiomdl.
	map_stem := filepath.stem(args.input)
	for e, i in pkg.exports {
		if !ue3.export_is_static_mesh(&pkg, e) {
			continue
		}
		meshes += 1
		mesh, mesh_d := ue3.read_static_mesh(&pkg, i)
		merge_diags(&diagnostics, &mesh_d)
		name := ue3.name_text(&pkg, e.object_name)
		dir := fmt.aprintf("%s/%s", args.output, map_stem)
		_ = os.make_directory_all(dir)
		for lod_index in 0..<len(mesh.lods) {
			obj := ue3.static_mesh_obj(&mesh, lod_index, mesh_transform())
			if len(obj) == 0 {
				continue
			}
			path := fmt.aprintf("%s/%s_L%d.obj", dir, name, lod_index)
			defer delete(path)
			if os.write_entire_file(path, obj) != nil {
				fmt.eprintfln("mapconv: cannot write %q", path)
				os.exit(2)
			}
			obj_files += 1
			delete(obj)
		}
		_ = os.make_directory_all(fmt.aprintf("%s/materials/mapconv", args.output))
		for section in mesh.lods[0].sections {
			mat_name := section.material_name
			if mat_name == "" {
				continue
			}
			tex_name := mat_name
			if section.material_ref > 0 {
				if minfo, md := ue3.read_material_texture(&pkg, int(section.material_ref) - 1); !diag.has_errors(&md) && minfo.has_texture {
					tex_name = minfo.texture_name
				}
			}
			material_info := ue3.Material_Texture {
				material_name = mat_name,
				texture_name  = tex_name,
				has_texture   = true,
			}
			body := ue3.material_vmt_for(mat_name, material_info)
			vmt_path := fmt.aprintf("%s/materials/mapconv/%s.vmt", args.output, mat_name)
			if verr := os.write_entire_file(vmt_path, transmute([]u8)body); verr != nil {
				fmt.eprintfln("VMTFAIL %s", vmt_path)
			}
			delete(vmt_path)
			delete(body)
		}
		// SMD and QC for the model path the VMF uses: embedded meshes are named
		// after the map package, referenced ones after their content package.
		smd := ue3.static_mesh_smd(&mesh, 0, mesh_transform())
		smd_path := fmt.aprintf("%s/%s_L0.smd", dir, name)
		if os.write_entire_file(smd_path, smd) == nil {
			smd_files += 1
		}
		delete(smd_path)
		delete(smd)
		model_path := fmt.aprintf("mapconv/%s/%s.mdl", map_stem, name)
		qc := ue3.static_mesh_qc(model_path, fmt.aprintf("%s_L0.smd", name), "mapconv")
		qc_path := fmt.aprintf("%s/%s.qc", dir, name)
		if os.write_entire_file(qc_path, qc) == nil {
			qc_files += 1
		}
		delete(qc_path)
		delete(qc)
		delete(model_path)
		ue3.static_mesh_destroy(&mesh)
	}

	texture_fallbacks := resolve_missing_basetextures(args.output)
	if texture_fallbacks > 0 {
		diag.warn(&diagnostics, "ue3.texture-fallback", fmt.aprintf("%d VMT basetexture(s) had no VTF and now point at an extracted texture", texture_fallbacks), args.input)
	}

	fmt.printfln(
		"extracted %d texture(s) of %d (%d skipped), %d OBJ file(s) from %d embedded mesh(es), %d referenced mesh(es) (%d SMD, %d QC)",
		written,
		total,
		skipped,
		obj_files,
		meshes,
		referenced_meshes,
		smd_files,
		qc_files,
	)
	print_diagnostics(&diagnostics, args.quiet, args.report)
}

// inspect_package prints the package summary and tables for `mapconv inspect`.
inspect_package :: proc(text, path: string, quiet: bool, report: string) {
	pkg, diagnostics := ue3.parse(transmute([]u8)text)
	if diag.has_errors(&diagnostics) {
		print_diagnostics(&diagnostics, quiet, report)
		os.exit(1)
	}
	if !quiet {
		fmt.print(ue3.inspect_text(&pkg, path))
	}
	fmt.printfln("diagnostics: %s", diag.summary(&diagnostics))
	if !quiet {
		print_diagnostics(&diagnostics, quiet, report)
	}
}

// validate_package parses the package and reports structural problems. There is
// no semantic validation yet because the IR import is pending.
validate_package :: proc(text, path: string, report: string) {
	_, diagnostics := ue3.parse(transmute([]u8)text)
	print_diagnostics(&diagnostics, false, report)
	if diag.has_errors(&diagnostics) {
		fmt.eprintfln("mapconv: validation failed: %s", diag.summary(&diagnostics))
		os.exit(1)
	}
	fmt.printfln("ok: %s", diag.summary(&diagnostics))
}

import_only :: proc(text, path: string, format: ir.Format) -> (ir.Document, diag.Diagnostics) {
	options := convert.Options {
		from = format,
	}
	return convert.import_only(transmute([]u8)text, path, options)
}

print_diagnostics :: proc(diagnostics: ^diag.Diagnostics, quiet: bool, report_path: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for item in diagnostics.items {
		if quiet && item.severity != .Error {
			continue
		}
		strings.write_string(&b, diag.format(item))
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	if text != "" {
		fmt.eprint(text)
	}
	if report_path != "" {
		if os.write_entire_file(report_path, text) != nil {
			fmt.eprintfln("mapconv: cannot write report %q", report_path)
		}
	}
}
