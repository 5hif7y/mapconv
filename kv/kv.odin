// Package kv is the shared key/value block tree used by every Valve-style text
// format in this project: VMF files and the entity lump of a BSP.
//
// The grammar is deliberately permissive: quoted key/value pairs, named blocks
// (`world { ... }`), unnamed blocks (`{ ... }`, the entity lump), `//` comments
// and escape sequences. Unknown blocks and keys are kept so a format adapter can
// preserve them.
package kv

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
		if c == '/' && t.pos + 1 < len(t.src) && t.src[t.pos + 1] == '/' {
			for t.pos < len(t.src) && t.src[t.pos] != '\n' {
				t.pos += 1
			}
			continue
		}
		switch c {
		case '{':
			t.pos += 1
			return {.Open_Brace, "{", t.line}
		case '}':
			t.pos += 1
			return {.Close_Brace, "}", t.line}
		case '"':
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
		case:
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
				t.pos += 1
				continue
			}
			return {.Word, word, t.line}
		}
	}
	return {.EOF, "", t.line}
}

// Node is a parsed entry: either a key/value pair (`value` set) or a block
// (`is_block`, `children` set).
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
	nodes: [dynamic]Node,
}

// parse_tree turns text into a block tree. Errors are reported as diagnostics
// with line numbers; parsing continues where recovery is safe.
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

advance :: proc(p: ^Parser) -> Token {
	tok := current(p)
	if p.pos < len(p.tokens) {
		p.pos += 1
	}
	return tok
}

parse_node :: proc(p: ^Parser, d: ^diag.Diagnostics, path: string) -> (Node, bool) {
	tok := current(p)
	switch tok.kind {
	case .Open_Brace:
		advance(p)
		// Unnamed block: the entity lump of a BSP is a sequence of these.
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
		if current_kind(p) == .String {
			return Node{name = name, value = advance(p).text, line = tok.line}, true
		}
		diag.warn(d, "kv.dangling-word", "bare word without a block or value", path)
		return Node{name = name, line = tok.line}, true
	case .String:
		key := advance(p)
		if current_kind(p) != .String {
			diag.warn(d, "kv.key-without-value", "key has no value; ignored", key.text)
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
		diag.warn(d, "kv.unclosed-block", "block reaches end of file without '}'", path)
	}
	return children
}

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

child :: proc(n: ^Node, name: string) -> (^Node, bool) {
	for i in 0 ..< len(n.children) {
		if n.children[i].name == name && n.children[i].is_block {
			return &n.children[i], true
		}
	}
	return nil, false
}

value :: proc(n: ^Node, key: string) -> (string, bool) {
	for c in n.children {
		if !c.is_block && c.name == key {
			return c.value, true
		}
	}
	return "", false
}

line_of :: proc(n: ^Node, key: string) -> int {
	for c in n.children {
		if !c.is_block && c.name == key {
			return c.line
		}
	}
	return n.line
}

// escape quotes and backslashes for output.
escape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '"') && !strings.contains_rune(s, '\\') {
		return s
	}
	b := strings.builder_make()
	for c in s {
		switch c {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

// write_node emits one node (and its children) at the given indentation.
write_node :: proc(b: ^strings.Builder, n: ^Node, indent: int) {
	pad := strings.repeat("  ", indent)
	if n.is_block {
		strings.write_string(b, pad)
		strings.write_string(b, n.name)
		strings.write_string(b, "\n")
		strings.write_string(b, pad)
		strings.write_string(b, "{\n")
		for &child_node in n.children {
			write_node(b, &child_node, indent + 1)
		}
		strings.write_string(b, pad)
		strings.write_string(b, "}\n")
		return
	}
	strings.write_string(b, pad)
	strings.write_string(b, "\"")
	strings.write_string(b, escape(n.name))
	strings.write_string(b, "\" \"")
	strings.write_string(b, escape(n.value))
	strings.write_string(b, "\"\n")
}

// serialize re-emits a node verbatim, used to preserve unknown blocks.
serialize :: proc(n: ^Node) -> string {
	b := strings.builder_make()
	write_node(&b, n, 0)
	return strings.to_string(b)
}
