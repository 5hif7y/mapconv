// Package vmf implements the Source 1 Valve Map Format text format on top of the
// shared kv block tree: an importer into the canonical IR and an exporter back to
// VMF text.
//
// Scope (see docs/formats/vmf.md): world/entity key-values, solids, sides, plane
// definitions, texture projection axes, material references, editor blocks and
// unknown properties. Displacements, overlays, instances and embedded data are
// detected and reported instead of being silently dropped.
package vmf

import "../diag"
import "../kv"

// The VMF grammar is the shared key/value block tree; these aliases keep the
// adapter's public names stable.
Token_Kind :: kv.Token_Kind
Token :: kv.Token
Tokenizer :: kv.Tokenizer
Parser :: kv.Parser
Node :: kv.Node
Tree :: kv.Tree

tokenize :: proc(src: string) -> [dynamic]Token {
	return kv.tokenize(src)
}

parse_tree :: proc(src: string, d: ^diag.Diagnostics, path: string) -> Tree {
	return kv.parse_tree(src, d, path)
}

node_child :: proc(n: ^Node, name: string) -> (^Node, bool) {
	return kv.child(n, name)
}

node_value :: proc(n: ^Node, key: string) -> (string, bool) {
	return kv.value(n, key)
}

node_line :: proc(n: ^Node, key: string) -> int {
	return kv.line_of(n, key)
}

// serialize_node_verbatim re-emits a parsed block so unknown data survives an
// import/export round trip.
serialize_node_verbatim :: proc(n: ^Node) -> string {
	return kv.serialize(n)
}

escape :: proc(s: string) -> string {
	return kv.escape(s)
}
