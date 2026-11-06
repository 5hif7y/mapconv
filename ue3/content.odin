// Content packages: resolving references from a map to the packages that hold
// the assets.
//
// A cooked map does not embed its static meshes: the actor's StaticMeshComponent
// points at an import whose outer is another package (for example EngineMeshes),
// and that package is a sibling .ccpk in the cooked install. This module builds
// the name -> path index of a content directory and follows those imports.
package ue3

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../diag"

Content_Index :: struct {
	root:       string,
	packages:   map[string]string, // lower-case package base name -> path
	duplicates: int,
}

ascii_lower :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		if c >= 'A' && c <= 'Z' {
			strings.write_byte(&b, u8(c + ('a' - 'A')))
		} else {
			strings.write_byte(&b, u8(c))
		}
	}
	return strings.to_string(b)
}

// index_content walks a cooked install and indexes every package by base name.
content_index :: proc(root: string) -> (index: Content_Index, d: diag.Diagnostics) {
	d = diag.init()
	index.root = root
	index.packages = make(map[string]string)
	index_walk(root, &index, &d)
	if index.duplicates > 0 {
		diag.info(
			&d,
			"ue3.content-duplicates",
			fmt.aprintf("%d package(s) share a base name; the first one wins", index.duplicates),
		)
	}
	return
}

content_index_destroy :: proc(index: ^Content_Index) {
	for _, path in index.packages {
		delete(path)
	}
	delete(index.packages)
}

index_walk :: proc(dir: string, index: ^Content_Index, d: ^diag.Diagnostics) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		diag.warn(d, "ue3.content-unreadable", fmt.aprintf("cannot list %q", dir))
		return
	}
	for entry in entries {
		path, _ := filepath.join([]string{dir, entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			index_walk(path, index, d)
			continue
		}
		ext := filepath.ext(path)
		if ext != ".ccpk" && ext != ".ccmap" && ext != ".upk" {
			continue
		}
		base := ascii_lower(filepath.stem(path))
		key := strings.clone(base)
		if _, exists := index.packages[key]; exists {
			index.duplicates += 1
			delete(key)
			continue
		}
		index.packages[key] = strings.clone(path)
	}
}

// import_package walks an import's outer chain and returns the package that owns
// the referenced object plus the object name.
import_package :: proc(pkg: ^Package, value: i32) -> (package_name, object_name: string) {
	if value >= 0 {
		return "", package_index_name(pkg, value)
	}
	index := int(-value) - 1
	if index < 0 || index >= len(pkg.imports) {
		return "", ""
	}
	imp := pkg.imports[index]
	object_name = name_text(pkg, imp.object_name)
	for imp.outer_index < 0 {
		outer := int(-imp.outer_index) - 1
		if outer < 0 || outer >= len(pkg.imports) {
			break
		}
		imp = pkg.imports[outer]
		package_name = name_text(pkg, imp.object_name)
	}
	return
}

// Resolved_Mesh owns the package it read, because its export payload points into
// that buffer.
Resolved_Mesh :: struct {
	package_name: string,
	package_path: string,
	pkg:          Package,
	export_index: int,
	mesh:         Static_Mesh,
}

resolve_static_mesh :: proc(
	map_pkg: ^Package,
	mesh_ref: i32,
	index: ^Content_Index,
) -> (resolved: Resolved_Mesh, d: diag.Diagnostics) {
	d = diag.init()
	package_name, object_name := import_package(map_pkg, mesh_ref)
	if package_name == "" || object_name == "" {
		diag.warn(&d, "ue3.mesh-unresolved", fmt.aprintf("cannot resolve mesh reference %d", mesh_ref))
		return
	}
	path, found := index.packages[ascii_lower(package_name)]
	if !found {
		diag.warn(
			&d,
			"ue3.mesh-package-missing",
			fmt.aprintf("mesh %s: package %q is not in the content directory", object_name, package_name),
		)
		return
	}
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		diag.warn(&d, "ue3.mesh-package-unreadable", fmt.aprintf("cannot read %q", path))
		return
	}
	pkg, parse_d := parse(data)
	for item in parse_d.items {
		diag.add(&d, item.severity, item.code, item.message, item.object, item.loc)
	}
	delete(parse_d.items)
	if diag.has_errors(&d) {
		delete(data)
		return
	}
	for e, i in pkg.exports {
		if name_text(&pkg, e.object_name) != object_name {
			continue
		}
		if !export_is_static_mesh(&pkg, e) {
			continue
		}
		mesh, mesh_d := read_static_mesh(&pkg, i)
		for item in mesh_d.items {
			diag.add(&d, item.severity, item.code, item.message, item.object, item.loc)
		}
		delete(mesh_d.items)
		if diag.has_errors(&d) {
			delete(data)
			return
		}
		resolved = Resolved_Mesh {
			package_name = package_name,
			package_path = path,
			pkg          = pkg,
			export_index = i,
			mesh         = mesh,
		}
		return
	}
	diag.warn(
		&d,
		"ue3.mesh-not-found",
		fmt.aprintf("package %q has no StaticMesh named %q", package_name, object_name),
	)
	delete(data)
	return
}

resolved_mesh_destroy :: proc(resolved: ^Resolved_Mesh) {
	static_mesh_destroy(&resolved.mesh)
	delete(resolved.pkg.data)
	// Name texts point into pkg.data, so only the arrays are freed here.
	delete(resolved.pkg.names)
	delete(resolved.pkg.imports)
	delete(resolved.pkg.exports)
	delete(resolved.pkg.summary.additional_packages_to_cook)
	delete(resolved.pkg.summary.compressed_chunks)
}
