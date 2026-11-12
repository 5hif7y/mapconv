package main

// A measurement is what an audit of one file says, in a form a machine can compare with
// the measurement of the same file taken yesterday. The text an audit prints is for a
// person; this struct is the same facts with fixed names, so a regression can be a
// failing exit code instead of a sentence somebody has to read.
//
// The rule the diff enforces is the one the project already states: coverage rises and
// never falls. A file whose bytes did not change may not interpret fewer of them, and no
// file may report more uninterpreted bytes than it did before.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "bsp"
import "diag"
import "ue3"

// Schema is the version of the document. A reader that does not know it must refuse the
// file rather than compare numbers whose meaning changed.
MEASURE_SCHEMA :: 1

Measure :: struct {
	path: string `json:"path"`,
	// format is the reader that produced the numbers: "bsp", "ue3" or "unreadable".
	format:          string `json:"format"`,
	bytes:           i64    `json:"bytes"`,
	interpreted:     i64    `json:"interpreted"`,
	uninterpreted:   i64    `json:"uninterpreted"`,
	classes:         i64    `json:"classes"`,
	objects:         i64    `json:"objects"`,
	lumps:           i64    `json:"lumps"`,
	lumps_refused:   i64    `json:"lumps_refused"`,
	lightmap_blocks: i64    `json:"lightmap_blocks"`,
	lightmap_lumps:  i64    `json:"lightmap_lumps_tiled"`,
	luxels:          i64    `json:"luxels"`,
	physx_elements:  i64    `json:"physx_elements"`,
	shader_maps:     i64    `json:"shader_maps"`,
	fractured_meshes:    i64 `json:"fractured_meshes"`,
	fractured_fragments: i64 `json:"fractured_fragments"`,
	speedtree_objects:   i64 `json:"speedtree_objects"`,
	speedtree_bytes:     i64 `json:"speedtree_bytes"`,
}

Measure_Document :: struct {
	tool:   string    `json:"tool"`,
	schema: int       `json:"schema"`,
	files:  []Measure `json:"files"`,
	totals: Measure   `json:"totals"`,
}

measure_destroy :: proc(document: ^Measure_Document) {
	for file in document.files {
		delete(file.path)
		delete(file.format)
	}
	delete(document.files)
}

// measure_document builds a document whose file list the caller owns.
measure_document :: proc(files: []Measure, allocator := context.allocator) -> Measure_Document {
	document := Measure_Document {
		tool   = "mapconv",
		schema = MEASURE_SCHEMA,
		files  = make([]Measure, len(files), allocator),
	}
	copy(document.files, files)
	totals := Measure {
		path   = "totals",
		format = "all",
	}
	for file in document.files {
		totals.bytes += file.bytes
		totals.interpreted += file.interpreted
		totals.uninterpreted += file.uninterpreted
		totals.classes += file.classes
		totals.objects += file.objects
		totals.lumps += file.lumps
		totals.lumps_refused += file.lumps_refused
		totals.lightmap_blocks += file.lightmap_blocks
		totals.lightmap_lumps += file.lightmap_lumps
		totals.luxels += file.luxels
		totals.physx_elements += file.physx_elements
		totals.shader_maps += file.shader_maps
		totals.fractured_meshes += file.fractured_meshes
		totals.fractured_fragments += file.fractured_fragments
		totals.speedtree_objects += file.speedtree_objects
		totals.speedtree_bytes += file.speedtree_bytes
	}
	document.totals = totals
	return document
}

measure_text :: proc(document: ^Measure_Document) -> string {
	b := strings.builder_make()
	for file in document.files {
		name := filepath.base(file.path)
		fmt.sbprintf(&b, "%-28s %-10s %14d B  interpreted %14d  uninterpreted %8d\n",
			name, file.format, file.bytes, file.interpreted, file.uninterpreted)
	}
	totals := document.totals
	fmt.sbprintf(&b,
		"%d file(s), %d B: interpreted %d (%.4f%%), uninterpreted %d\n",
		len(document.files), totals.bytes, totals.interpreted,
		percent_of(totals.interpreted, totals.bytes), totals.uninterpreted)
	// The counters are printed because they are what the diff compares: a run that
	// interprets the same bytes while decoding fewer luxels is not a run that held still.
	fmt.sbprintf(&b,
		"classes %d, objects %d, lumps %d (%d refused), lightmap blocks %d, lightmap lumps %d, luxels %d, physx elements %d, shader maps %d, fractured meshes %d (%d fragments)\n",
		totals.classes, totals.objects, totals.lumps, totals.lumps_refused,
		totals.lightmap_blocks, totals.lightmap_lumps, totals.luxels,
		totals.physx_elements, totals.shader_maps, totals.fractured_meshes,
		totals.fractured_fragments)
	fmt.sbprintf(&b, "speedtrees %d (%d bytes of SDK container)\n",
		totals.speedtree_objects, totals.speedtree_bytes)
	return strings.to_string(b)
}

percent_of :: proc(part, total: i64) -> f64 {
	if total <= 0 {
		return 0
	}
	return 100.0 * f64(part) / f64(total)
}

// measure_one reads a file and audits it with the reader its format names. A file that
// cannot be read is not skipped: it is measured as fully uninterpreted, so a corpus that
// stops being readable shows up as a regression instead of as a shorter list.
measure_one :: proc(path: string) -> Measure {
	measure := Measure {
		path = strings.clone(path),
	}
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		measure.format = strings.clone("unreadable")
		return measure
	}
	defer delete(data)
	measure.bytes = i64(len(data))

	if strings.has_suffix(path, ".bsp") || strings.has_suffix(path, ".BSP") {
		measure.format = strings.clone("bsp")
		audit := bsp.audit_lumps(data)
		// What the reader explains is the lump bytes it attributed, plus the header it
		// parsed and the zero alignment between lumps. The rest is the residual, and it
		// is a number on every run: two bytes in this corpus.
		credited := audit.interpreted + bsp.HEADER_BYTES + audit.padding
		if credited > audit.file_bytes {
			credited = audit.file_bytes
		}
		measure.interpreted = credited
		measure.uninterpreted = audit.file_bytes - credited
		measure.lumps = i64(len(audit.rows))
		for row in audit.rows {
			if !row.interpreted {
				measure.lumps_refused += 1
			}
		}
		measure.lightmap_blocks = i64(audit.lightmap_blocks)
		measure.lightmap_lumps = i64(audit.lightmap_tiled)
		measure.luxels = audit.lightmap_luxels
		bsp.audit_lumps_destroy(&audit)
		return measure
	}

	measure.format = strings.clone("ue3")
	pkg, diagnostics := ue3.parse(data)
	if diag.has_errors(&diagnostics) {
		// The reader refused the package: nothing is attributed, and saying so is the
		// measurement.
		measure.uninterpreted = measure.bytes
		return measure
	}
	audit, _ := ue3.audit_package(&pkg)
	// Payload plus the header and tables the parser walked, which is the same credit
	// the text audit prints.
	credited := audit.interpreted + audit.header
	if credited > audit.file_size {
		credited = audit.file_size
	}
	measure.interpreted = credited
	measure.uninterpreted = audit.file_size - credited
	for row in audit.rows {
		if row.class_name != "" && row.payload > 0 {
			measure.classes += 1
		}
	}
	// The exports the reader walked, not the ones a diagnostic listed: this is the
	// count the audit itself reports, so a run that stops walking objects shows up.
	measure.objects = i64(len(audit.objects))
	if measure.objects == 0 {
		for row in audit.rows {
			measure.objects += i64(row.count)
		}
	}
	measure.shader_maps = i64(audit.shader_maps)
	measure.fractured_meshes = i64(audit.fractured_meshes)
	measure.fractured_fragments = audit.fractured_fragments
	measure.speedtree_objects = i64(audit.speedtree_objects)
	measure.speedtree_bytes = audit.speedtree_bytes
	measure.physx_elements = i64(audit.physx_elements)
	delete(audit.rows)
	delete(audit.objects)
	return measure
}

// walk_corpus measures every file whose extension names a reader, in a stable order so
// two runs of the same tree produce the same document.
walk_corpus :: proc(dir: string, out: ^[dynamic]Measure) {
	entries, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintln("audit: cannot read", dir)
		return
	}
	defer delete(entries)
	for entry in entries {
		if entry.name == "." || entry.name == ".." {
			continue
		}
		path := fmt.aprintf("%s/%s", dir, entry.name)
		defer delete(path)
		if entry.type == .Directory {
			walk_corpus(path, out)
			continue
		}
		extension := filepath.ext(path)
		switch extension {
		case ".bsp", ".BSP", ".ccmap", ".ccpk", ".u":
			append(out, measure_one(path))
		}
	}
}

// write_measure_document prints or writes the document. The caller says where.
write_measure_document :: proc(document: ^Measure_Document, path: string) -> bool {
	data, err := json.marshal(document^, {pretty = true})
	if err != nil {
		fmt.eprintfln("audit: cannot build the json document: %v", err)
		return false
	}
	defer delete(data)
	document_text := string(data)
	document_text = strings.concatenate({document_text, "\n"})
	defer delete(document_text)
	if path == "" {
		fmt.print(document_text)
		return true
	}
	if write_err := os.write_entire_file(path, transmute([]u8)document_text); write_err != nil {
		fmt.eprintfln("audit: cannot write %q", path)
		return false
	}
	return true
}

// read_measure_document reads a document written by this tool and refuses one whose
// schema it does not know, because comparing numbers of different meanings is worse than
// not comparing them.
read_measure_document :: proc(path: string) -> (document: Measure_Document, ok: bool) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("audit: cannot read the baseline %q", path)
		return document, false
	}
	defer delete(data)
	if err := json.unmarshal(data, &document); err != nil {
		fmt.eprintfln("audit: %q is not a measurement document", path)
		return document, false
	}
	if document.schema != MEASURE_SCHEMA {
		fmt.eprintfln("audit: %q has schema %d, this build reads %d",
			path, document.schema, MEASURE_SCHEMA)
		measure_destroy(&document)
		return document, false
	}
	return document, true
}

Regression :: struct {
	path:   string,
	detail: string,
}

// diff_documents compares two measurements and returns every place where coverage fell.
// Only files whose size did not change are compared field by field: a corpus that grew is
// not a corpus that regressed, but a file that shrank its attributed bytes is.
diff_documents :: proc(baseline, current: ^Measure_Document) -> [dynamic]Regression {
	regressions := make([dynamic]Regression, 0, 8, context.allocator)
	previous := make(map[string]Measure, len(baseline.files), context.allocator)
	keys := make([dynamic]string, 0, len(baseline.files), context.allocator)
	defer {
		for key in keys {
			delete(key)
		}
		delete(keys)
		delete(previous)
	}
	for file in baseline.files {
		key := measure_key(file.path, file.bytes)
		append(&keys, key)
		previous[key] = file
	}
	seen := make(map[string]bool, len(current.files), context.allocator)
	defer delete(seen)
	for file in current.files {
		key := measure_key(file.path, file.bytes)
		defer delete(key)
		seen[filepath.base(file.path)] = true
		old, known := previous[key]
		if !known {
			continue
		}
		if file.interpreted < old.interpreted {
			append(&regressions, Regression {
				path   = file.path,
				detail = fmt.aprintf("interpreted %d bytes, was %d", file.interpreted, old.interpreted),
			})
		}
		if file.uninterpreted > old.uninterpreted {
			append(&regressions, Regression {
				path   = file.path,
				detail = fmt.aprintf("uninterpreted %d bytes, was %d", file.uninterpreted, old.uninterpreted),
			})
		}
		for counter in COUNTERS {
			before := counter_of(old, counter.name)
			after := counter_of(file, counter.name)
			if after < before {
				append(&regressions, Regression {
					path   = file.path,
					detail = fmt.aprintf("%s fell to %d, was %d", counter.name, after, before),
				})
			}
		}
	}
	for file in baseline.files {
		// Missing means gone by name. A file that is still there with different bytes is
		// a different measurement, and the diff says nothing about it.
		if !seen[filepath.base(file.path)] {
			append(&regressions, Regression {
				path   = strings.clone(file.path),
				detail = strings.clone("missing from the new measurement"),
			})
		}
	}
	return regressions
}

// measure_key names a measured file across two runs. The directory can differ -- the
// corpus is reached by different paths on different machines -- but the name alone is not
// enough: this corpus holds two maps called de_nuke.bsp, and the size is what tells them
// apart. A file whose bytes changed therefore has a different key, and is not compared
// against a measurement of something else.
measure_key :: proc(path: string, bytes: i64) -> string {
	return fmt.aprintf("%s|%d", filepath.base(path), bytes)
}

Counter :: struct {
	name: string,
}

COUNTERS := [?]Counter {
	{"classes"},
	{"objects"},
	{"lumps"},
	{"lightmap_blocks"},
	{"lightmap_lumps_tiled"},
	{"luxels"},
	{"physx_elements"},
	{"shader_maps"},
	{"fractured_meshes"},
	{"fractured_fragments"},
	{"speedtree_objects"},
	{"speedtree_bytes"},
}

counter_of :: proc(measure: Measure, name: string) -> i64 {
	switch name {
	case "classes":
		return measure.classes
	case "objects":
		return measure.objects
	case "lumps":
		return measure.lumps
	case "lightmap_blocks":
		return measure.lightmap_blocks
	case "lightmap_lumps_tiled":
		return measure.lightmap_lumps
	case "luxels":
		return measure.luxels
	case "physx_elements":
		return measure.physx_elements
	case "shader_maps":
		return measure.shader_maps
	case "fractured_meshes":
		return measure.fractured_meshes
	case "fractured_fragments":
		return measure.fractured_fragments
	case "speedtree_objects":
		return measure.speedtree_objects
	case "speedtree_bytes":
		return measure.speedtree_bytes
	}
	return 0
}

regressions_text :: proc(regressions: []Regression) -> string {
	b := strings.builder_make()
	if len(regressions) == 0 {
		fmt.sbprintfln(&b, "diff: no regression")
		return strings.to_string(b)
	}
	fmt.sbprintfln(&b, "diff: %d regression(s)", len(regressions))
	for regression in regressions {
		fmt.sbprintfln(&b, "  %s: %s", filepath.base(regression.path), regression.detail)
	}
	return strings.to_string(b)
}

// sort_measures orders the file list so two runs of the same tree are comparable byte by
// byte, which makes the document usable as a fixture.
sort_measures :: proc(files: []Measure) {
	slice.sort_by(files, proc(a, b: Measure) -> bool {
		left := filepath.base(a.path)
		right := filepath.base(b.path)
		if left != right {
			return left < right
		}
		if a.bytes != b.bytes {
			return a.bytes < b.bytes
		}
		return a.path < b.path
	})
}
