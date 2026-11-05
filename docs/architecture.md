# mapconv architecture

`mapconv` is one pipeline with pluggable ends:

```text
native text -> importer -> canonical IR -> transform + mapping -> exporter -> native text
```

Nothing in the middle knows which two formats are involved, so every supported
format can convert to every other one through the same code path.

## Package boundaries

| Package | Responsibility | Must not |
| --- | --- | --- |
| `geom` | vectors, matrices, planes, windings, clipping, tolerances, numeric formatting | know about a map format |
| `ir` | canonical document: metadata, brushes, faces, entities, materials, extensions | contain format-specific types or parsing |
| `xform` | coordinate systems, unit scales, plane/winding/texture-projection transforms | hard-code conversion constants outside the declared systems |
| `diag` | severity, stable diagnostic codes, deterministic reporting | decide conversion policy |
| `profile` | entity/material mapping tables per game or engine | perform I/O or geometry work |
| `vmf` | Valve Map Format tokenizer, block tree, importer, exporter | know about Unreal types |
| `t3d` | T3D parser, importer, exporter | know about VMF or Source semantics |
| `convert` | orchestration, validation, fidelity reporting, inspection | embed format syntax |
| `main` | CLI, exit codes, report writing | contain conversion logic |

The dependency graph is acyclic: `geom <- ir <- xform`, `vmf`/`t3d` depend on
`geom`, `ir`, `diag` (and `xform` for their declared frames), `convert` depends on
the adapters, `main` depends on `convert`.

## Invariants

1. **Authoring data is never replaced by evaluated geometry.** Brushes keep their
   authored planes; face windings are marked `Authored` or `Derived`. Transforming
   a derived winding clears it so the next exporter re-evaluates it in the target
   frame instead of double-approximating it.
2. **Every approximation is visible.** Importers and exporters report what they
   could not represent (`docs/diagnostics.md`). A conversion never claims
   full fidelity.
3. **Conversions are deterministic.** Identical input and options produce
   identical output: no map iteration in serializers, no platform-dependent float
   formatting (`geom.f64_string`), stable id allocation.
4. **Transforms are explicit and testable.** No adapter applies a sign flip or a
   unit factor; only `xform` does, and only through a declared
   `CoordinateSystem`.

## Data flow for a conversion

1. Import: native text -> `ir.Document` + `diag.Diagnostics`.
2. If source and target frames differ: build the transform with
   `xform.transform_between`, transform planes, authored windings, entity origins
   and texture projections, then record the source frame's replacement.
3. Entity mapping through the selected `profile`: classes may be renamed (with a
   note), have no actor equivalent (their brushes move to the world), or stay
   unmapped (warning).
4. Validate: degenerate planes, brushes with too few faces, non-finite
   coordinates, non-convex brushes, missing materials.
5. Export through the target adapter, which re-derives windings where the target
   needs explicit vertices (T3D) and reports format limitations (for example
   subtractive CSG in VMF).

## Roadmap hooks

The IR already carries what future adapters need without changing the pipeline:
`Csg_Op`, `TexProjection`, entity extensions, opaque `Extension` blocks and
resource references. GoldSrc `.map` and Valve 220 would become two more adapters
(`ir.Format.Goldsrc_MAP`, `ir.Format.Valve_220` are reserved) with no change to
`convert`.
