// Package vmf implements the Source 1 Valve Map Format text format: a
// tokenizer, a generic block tree, an importer into the canonical IR and an
// exporter back to VMF text.
//
// Scope (see docs/formats/vmf.md): world/entity key-values, solids, sides, plane
// definitions, texture projection axes, material references, editor blocks and
// unknown properties. Displacements, overlays, instances and embedded data are
// detected and reported instead of being silently dropped.
package vmf

import "core:fmt"
import "core:strings"
import "../diag"

Token_Kind :: enum {
	Word,
	String,
	Open_Brace,
	Close_Brace,
	EOF,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	line: int,
}

Tokenizer :: struct {
	src:  string,
	pos:  int,
	line: int,
}

tokenize :: proc(src: string) -> [dynamic]Token {
	t := Tokenizer{src = src, line = 1}
	tokens := make([dynamic]Token, 0, 256)
	for {
		tok := next_token(&t)
		append(&tokens, tok)
		if tok.kind == .EOF {
			break
		}
	}
	return tokens
}

is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

next_token :: proc(t: ^Tokenizer) -> Token {
	for t.pos < len(t.src) {
		c := t.src[t.pos]
		if c == '\n' {
			t.line += 1
			t.pos += 1
			continue
		}
		if is_space(c) {
			t.pos += 1
			continue
		}
		// Both VMF dialects in the wild carry // comments; skip them.
		if c == '/' && t.pos + 1 < len(t.src) && t.src[t.pos + 1] == '/' {
			for t.pos < len(t.src) && t.src[t.pos] != '\n' {
				t.pos += 1
			}
			continue
		}
		if c == '{' {
			t.pos += 1
			return {.Open_Brace, "{", t.line}
		}
		if c == '}' {
			t.pos += 1
			return {.Close_Brace, "}", t.line}
		}
		if c == '"' {
			line := t.line
			t.pos += 1
			b := strings.builder_make()
			for t.pos < len(t.src) {
				ch := t.src[t.pos]
				if ch == '\\' && t.pos + 1 < len(t.src) {
					next := t.src[t.pos + 1]
					switch next {
					case '"':
						strings.write_byte(&b, '"')
					case '\\':
						strings.write_byte(&b, '\\')
					case 'n':
						strings.write_byte(&b, '\n')
					case 't':
						strings.write_byte(&b, '\t')
					case:
						strings.write_byte(&b, next)
					}
					t.pos += 2
					continue
				}
				if ch == '"' {
					t.pos += 1
					break
				}
				if ch == '\n' {
					t.line += 1
				}
				strings.write_byte(&b, ch)
				t.pos += 1
			}
			return {.String, strings.clone(strings.to_string(b)), line}
		}
		// Bare word (block names such as `world` or `solid`).
		start := t.pos
		for t.pos < len(t.src) {
			ch := t.src[t.pos]
			if is_space(ch) || ch == '{' || ch == '}' || ch == '"' {
				break
			}
			t.pos += 1
		}
		word := t.src[start:t.pos]
		if len(word) == 0 {
			// Defensive: never loop forever on an unexpected byte.
			t.pos += 1
			continue
		}
		return {.Word, word, t.line}
	}
	return {.EOF, "", t.line}
}

// Node is the generic VMF block tree. It keeps unknown blocks and unknown keys
// intact so exports can write them back.
Node :: struct {
	name:     string,
	value:    string,
	is_block: bool,
	children: [dynamic]Node,
	line:     int,
}

Parser :: struct {
	tokens: [dynamic]Token,
	pos:    int,
}

Tree :: struct {
	nodes:     [dynamic]Node,
	authoring: [dynamic]Node, // top-level blocks kept verbatim for re-export
}

// parse_tree turns VMF text into a block tree. Errors are reported as
// diagnostics with line numbers; parsing continues where recovery is safe.
parse_tree :: proc(src: string, d: ^diag.Diagnostics, path: string) -> Tree {
	tokens := tokenize(src)
	p := Parser{tokens = tokens}
	tree := Tree {
		nodes = make([dynamic]Node, 0, 8),
	}
	for current_kind(&p) != .EOF {
		node, ok := parse_node(&p, d, path)
		if !ok {
			break
		}
		append(&tree.nodes, node)
	}
	return tree
}

current :: proc(p: ^Parser) -> Token {
	return p.tokens[p.pos] if p.pos < len(p.tokens) else Token{kind = .EOF}
}

current_kind :: proc(p: ^Parser) -> Token_Kind {
	return current(p).kind
}

peek_kind :: proc(p: ^Parser, offset: int) -> Token_Kind {
	i := p.pos + offset
	return p.tokens[i].kind if i < len(p.tokens) else Token_Kind.EOF
}

peek :: proc(p: ^Parser, offset: int) -> Token {
	i := p.pos + offset
	return p.tokens[i] if i < len(p.tokens) else Token{kind = .EOF}
}

advance :: proc(p: ^Parser) -> Token {
	tok := current(p)
	if p.pos < len(p.tokens) {
		p.pos += 1
	}
	return tok
}

// parse_node accepts either `name { ... }` or `"key" "value"`.
parse_node :: proc(p: ^Parser, d: ^diag.Diagnostics, path: string) -> (Node, bool) {
	tok := current(p)
	switch tok.kind {
	case .Open_Brace:
		advance(p)
		// A stray opening brace: parse its children into a placeholder block so
		// the rest of the file still parses.
		children := parse_children(p, d, path)
		name := fmt.aprintf("unnamed@%d", tok.line)
		return Node{name = name, is_block = true, children = children, line = tok.line}, true
	case .Close_Brace:
		advance(p)
		return Node{}, false
	case .Word:
		advance(p)
		name := tok.text
		if current_kind(p) == .Open_Brace {
			advance(p)
			children := parse_children(p, d, path)
			return Node{name = name, is_block = true, children = children, line = tok.line}, true
		}
		// Bare word followed by a quoted value is not standard VMF but appears in
		// hand-edited files; treat it as a key/value pair.
		if current_kind(p) == .String {
			return Node{name = name, value = advance(p).text, line = tok.line}, true
		}
		diag.warn(d, "vmf.dangling-word", "bare word without a block or value", path)
		return Node{name = name, line = tok.line}, true
	case .String:
		key := advance(p)
		if current_kind(p) != .String {
			diag.warn(d, "vmf.key-without-value", "key has no value; ignored", key.text)
			return Node{name = key.text, line = key.line}, true
		}
		value := advance(p)
		return Node{name = key.text, value = value.text, line = key.line}, true
	case .EOF:
		return Node{}, false
	}
	return Node{}, false
}

parse_children :: proc(p: ^Parser, d: ^diag.Diagnostics, path: string) -> [dynamic]Node {
	children := make([dynamic]Node, 0, 8)
	for current_kind(p) != .Close_Brace && current_kind(p) != .EOF {
		node, ok := parse_node(p, d, path)
		if !ok {
			break
		}
		append(&children, node)
	}
	if current_kind(p) == .Close_Brace {
		advance(p)
	} else {
		diag.warn(d, "vmf.unclosed-block", "block reaches end of file without '}'", path)
	}
	return children
}

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

node_child :: proc(n: ^Node, name: string) -> (^Node, bool) {
	for i in 0 ..< len(n.children) {
		if n.children[i].name == name && n.children[i].is_block {
			return &n.children[i], true
		}
	}
	return nil, false
}

node_value :: proc(n: ^Node, key: string) -> (string, bool) {
	for c in n.children {
		if !c.is_block && c.name == key {
			return c.value, true
		}
	}
	return "", false
}

node_line :: proc(n: ^Node, key: string) -> int {
	for c in n.children {
		if !c.is_block && c.name == key {
			return c.line
		}
	}
	return n.line
}
