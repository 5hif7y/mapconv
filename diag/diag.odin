// Package diag carries conversion diagnostics. Every approximation, dropped
// feature or unknown field that survives a conversion pass has to show up here;
// see docs/diagnostics.md for the categories and the stable codes.
package diag

import "core:fmt"
import "core:strings"

Severity :: enum {
	Info,
	Warning,
	Error,
}

severity_name :: proc(s: Severity) -> string {
	switch s {
	case .Info:
		return "info"
	case .Warning:
		return "warning"
	case .Error:
		return "error"
	}
	return "unknown"
}

// Location points back into a source file when the adapter knows it.
Location :: struct {
	file: string,
	line: int,
	valid: bool,
}

at :: proc(file: string, line: int) -> Location {
	return {file, line, true}
}

Diagnostic :: struct {
	severity: Severity,
	// Stable machine-readable code, e.g. "vmf.unknown-version".
	code:    string,
	message: string,
	// Human-readable path of the affected object, e.g. "world.solid[3].side[2]".
	object:  string,
	loc:        Location,
}

Diagnostics :: struct {
	items:  [dynamic]Diagnostic,
	counts: [3]int,
}

init :: proc() -> Diagnostics {
	return Diagnostics{items = make([dynamic]Diagnostic, 0, 8)}
}

add :: proc(d: ^Diagnostics, severity: Severity, code, message: string, object := "", loc := Location{}) {
	append(&d.items, Diagnostic{severity, code, message, object, loc})
	d.counts[int(severity)] += 1
}

info :: proc(d: ^Diagnostics, code, message: string, object := "") {
	add(d, .Info, code, message, object)
}

warn :: proc(d: ^Diagnostics, code, message: string, object := "") {
	add(d, .Warning, code, message, object)
}

err :: proc(d: ^Diagnostics, code, message: string, object := "") {
	add(d, .Error, code, message, object)
}

count :: proc(d: ^Diagnostics, severity: Severity) -> int {
	return d.counts[int(severity)]
}

has_errors :: proc(d: ^Diagnostics) -> bool {
	return d.counts[int(Severity.Error)] > 0
}

has_warnings :: proc(d: ^Diagnostics) -> bool {
	return d.counts[int(Severity.Warning)] > 0
}

// summary is a one line aggregate: "1 error, 3 warnings, 2 notes".
summary :: proc(d: ^Diagnostics) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	first := true
	for sev in ([]Severity{.Error, .Warning, .Info}) {
		n := d.counts[int(sev)]
		if n == 0 {
			continue
		}
		if !first {
			strings.write_string(&b, ", ")
		}
		first = false
		plural := n == 1 ? "" : "s"
		switch sev {
		case .Error:
			fmt.sbprintf(&b, "%d error%s", n, plural)
		case .Warning:
			fmt.sbprintf(&b, "%d warning%s", n, plural)
		case .Info:
			fmt.sbprintf(&b, "%d note%s", n, plural)
		}
	}
	if first {
		return "no diagnostics"
	}
	return strings.clone(strings.to_string(b))
}

// format renders one diagnostic as "severity: code: message (object) [file:line]".
format :: proc(x: Diagnostic) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "%s: %s: %s", severity_name(x.severity), x.code, x.message)
	if len(x.object) > 0 {
		fmt.sbprintf(&b, " [%s]", x.object)
	}
	if x.loc.valid {
		fmt.sbprintf(&b, " (%s:%d)", x.loc.file, x.loc.line)
	}
	return strings.clone(strings.to_string(b))
}

// write_all appends every diagnostic, one per line, to the builder.
write_all :: proc(b: ^strings.Builder, d: ^Diagnostics) {
	for x in d.items {
		strings.write_string(b, format(x))
		strings.write_byte(b, '\n')
	}
}
