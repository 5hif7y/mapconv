// mapconv is a multi-format, bidirectional map conversion toolkit.
//
// Commands:
//   mapconv convert  --input <file> --output <file> [options]
//   mapconv inspect  --input <file>
//   mapconv validate --input <file>
//
// Exit codes: 0 success, 1 the conversion produced errors, 2 usage or I/O error.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "convert"
import "diag"
import "ir"

VERSION :: "0.1.0"

USAGE :: `mapconv — multi-format map conversion toolkit

Usage:
  mapconv convert  --input <file> --output <file> [options]
  mapconv inspect  --input <file> [--from <format>]
  mapconv validate --input <file> [--from <format>]
  mapconv --version

Options:
  --input <file>       map to read
  --output <file>      map to write (convert only)
  --from <format>      override the input format: vmf, t3d
  --to <format>        override the output format: vmf, t3d
  --profile <name>     entity mapping profile (default, source1-to-unreal3,
                       unreal3-to-source1)
  --report <file>      write the diagnostic report to a file as well as stderr
  --quiet              only print errors
  --no-materials       skip the per-material notes

Supported formats:
  vmf   Source 1 Valve Map Format (text)
  t3d   Unreal Engine 3 T3D text interchange

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
	quiet:    bool,
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
			case "--input", "--output", "--from", "--to", "--profile", "--report":
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
			}
			continue
		}
		switch flag {
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
	return args, true
}

parse_format :: proc(text: string) -> (format: ir.Format, ok: bool) {
	switch strings.to_lower(text) {
	case "auto", "":
		return .Unknown, true
	case "vmf", "source", "source1":
		return .Source_VMF, true
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
	doc, diagnostics := import_only(text, args.input, format)
	convert.validate_document(&doc, &diagnostics)
	print_diagnostics(&diagnostics, false, args.report)
	if diag.has_errors(&diagnostics) {
		fmt.eprintfln("mapconv: validation failed: %s", diag.summary(&diagnostics))
		os.exit(1)
	}
	fmt.printfln("ok: %s", diag.summary(&diagnostics))
}

import_only :: proc(text, path: string, format: ir.Format) -> (ir.Document, diag.Diagnostics) {
	options := convert.Options {
		from = format,
		to   = format,
	}
	result := convert.convert_text(text, path, options)
	return result.doc, result.diagnostics
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
