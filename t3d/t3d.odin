// Package t3d implements the Unreal Engine 3 T3D text interchange format: a
// line-oriented parser for the UnrealEd text representation, an importer into the
// canonical IR and an exporter back to T3D.
//
// T3D is a text interchange format, not a Unreal package format. Native .upk/.udk
// parsing is explicitly out of scope (see docs/formats/t3d.md).
package t3d

import "core:strings"
import "../diag"
import "../ir"

Attr :: struct {
	key:   string,
	value: string,
}

Data_Line :: struct {
	key:   string,
	value: string,
	line:  int,
}

Node :: struct {
	keyword:  string, // "map", "level", "actor", "brush", "polylist", "polygon", ...
	attrs:    [dynamic]Attr,
	data:     [dynamic]Data_Line,
	children: [dynamic]Node,
	line:     int,
}

Tree :: struct {
	roots:  [dynamic]Node,
	surface: [dynamic]Data_Line,
	surface_seen: bool,
}

Tokenize :: struct {
	tokens: [dynamic]string,
}

equal_fold :: proc(a, b: string) -> bool {
	return strings.equal_fold(a, b)
}

// tokenize_line splits a T3D statement header on whitespace while keeping quoted
// and single-quoted values in one token.
tokenize_line :: proc(line: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 8)
	b := strings.builder_make()
	quote: u8 = 0
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if quote != 0 {
			strings.write_byte(&b, c)
			if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '"', '\'':
			quote = c
			strings.write_byte(&b, c)
		case ' ', '\t', '\r':
			if strings.builder_len(b) > 0 {
				append(&out, strings.clone(strings.to_string(b)))
				strings.builder_reset(&b)
			}
		case:
			strings.write_byte(&b, c)
		}
	}
	if strings.builder_len(b) > 0 {
		append(&out, strings.clone(strings.to_string(b)))
	}
	return out
}

make_node :: proc(keyword: string, line: int) -> Node {
	return {
		keyword  = keyword,
		line     = line,
		attrs    = make([dynamic]Attr, 0, 4),
		data     = make([dynamic]Data_Line, 0, 8),
		children = make([dynamic]Node, 0, 4),
	}
}

parse_tree :: proc(src: string, d: ^diag.Diagnostics, path: string) -> Tree {
	tree := Tree {
		roots   = make([dynamic]Node, 0, 4),
		surface = make([dynamic]Data_Line, 0, 0),
	}
	lines := strings.split_lines(src)
	pos := 0

	// Top level: blocks and stray data lines.
	for pos < len(lines) {
		text := strings.trim_space(lines[pos])
		if text == "" {
			pos += 1
			continue
		}
		tokens := tokenize_line(text)
		if len(tokens) == 0 {
			pos += 1
			continue
		}
		if equal_fold(tokens[0], "Begin") {
			node, ok := parse_block(lines, &pos, d, path)
			if ok {
				append(&tree.roots, node)
			}
			continue
		}
		if equal_fold(tokens[0], "End") {
			diag.warn(d, "t3d.unexpected-end", "End without a matching Begin", path)
			pos += 1
			continue
		}
		// Data outside any block is kept in the tree as a nameless block so the
		// importer can report it without losing text.
		entry := parse_data_line(tokens, text, pos + 1)
		node := make_node("", pos + 1)
		append(&node.data, entry)
		append(&tree.roots, node)
		pos += 1
	}

	for &root in tree.roots {
		if equal_fold(root.keyword, "surface") {
			tree.surface_seen = true
			for entry in root.data {
				append(&tree.surface, entry)
			}
		}
	}
	return tree
}

parse_block :: proc(lines: []string, pos: ^int, d: ^diag.Diagnostics, path: string) -> (Node, bool) {
	text := strings.trim_space(lines[pos^])
	tokens := tokenize_line(text)
	line_no := pos^ + 1
	if len(tokens) < 2 {
		diag.warn(d, "t3d.begin-without-keyword", "'Begin' without a block keyword", path)
		pos^ += 1
		return {}, false
	}
	node := make_node(strings.to_lower(tokens[1]), line_no)
	for i in 2 ..< len(tokens) {
		if eq := strings.index_byte(tokens[i], '='); eq > 0 {
			append(&node.attrs, Attr{strings.to_lower(tokens[i][:eq]), tokens[i][eq + 1:]})
		}
	}
	pos^ += 1

	for pos^ < len(lines) {
		inner := strings.trim_space(lines[pos^])
		if inner == "" {
			pos^ += 1
			continue
		}
		inner_tokens := tokenize_line(inner)
		if len(inner_tokens) == 0 {
			pos^ += 1
			continue
		}
		switch {
		case equal_fold(inner_tokens[0], "End"):
			keyword := ""
			if len(inner_tokens) > 1 {
				keyword = strings.to_lower(inner_tokens[1])
			}
			if keyword != "" && !equal_fold(node.keyword, keyword) {
				diag.warn(
					d,
					"t3d.mismatched-end",
					strings.concatenate({"End ", keyword, " closes Begin ", node.keyword}),
					path,
				)
			}
			pos^ += 1
			return node, true
		case equal_fold(inner_tokens[0], "Begin"):
			child, ok := parse_block(lines, pos, d, path)
			if ok {
				append(&node.children, child)
			}
		case:
			append(&node.data, parse_data_line(inner_tokens, inner, pos^ + 1))
			pos^ += 1
		}
	}
	diag.warn(d, "t3d.unclosed-block", "file ends inside an open block", node.keyword)
	return node, true
}

// parse_data_line accepts "Key=Value" and "Key  value" statements.
parse_data_line :: proc(tokens: [dynamic]string, text: string, line: int) -> Data_Line {
	first := tokens[0]
	if eq := strings.index_byte(first, '='); eq > 0 {
		value := first[eq + 1:]
		if len(tokens) > 1 {
			value = strings.trim_space(text[len(first) + 1:])
		}
		return {key = strings.to_lower(first[:eq]), value = value, line = line}
	}
	return {key = strings.to_lower(first), value = strings.trim_space(text[len(first):]), line = line}
}

node_attr :: proc(n: ^Node, key: string) -> (string, bool) {
	for a in n.attrs {
		if a.key == key {
			return a.value, true
		}
	}
	return "", false
}

node_data :: proc(n: ^Node, key: string) -> (string, bool) {
	for entry in n.data {
		if entry.key == key {
			return entry.value, true
		}
	}
	return "", false
}

append_ext :: proc(exts: ^[dynamic]ir.Extension, name, data: string) {
	append(exts, ir.Extension{name = name, data = data})
}

child_by_keyword :: proc(n: ^Node, keyword: string) -> (^Node, bool) {
	for i in 0 ..< len(n.children) {
		if equal_fold(n.children[i].keyword, keyword) {
			return &n.children[i], true
		}
	}
	return nil, false
}
