# mapconv

A multi-format, bidirectional map conversion toolkit for game engines and modding
workflows, built around a shared, engine-independent intermediate representation.

**Status: early development.** The Source 1 VMF and Unreal Engine 3 T3D adapters,
the canonical IR, the coordinate/unit transforms, the diagnostics pipeline and
the CLI exist and are tested. Conversion is *not* lossless; every approximation is
reported. The CLI is not yet a stable contract.

The first supported pair is **Source 1 VMF <-> Unreal Engine 3 T3D**. The
architecture is format-pair independent: every adapter converts through the IR, so
adding a format adds 2N conversions instead of 1.

## Quick start

Requires [Odin](https://odin-lang.org). No third-party dependencies.

```sh
make build                       # or: odin build . -out:mapconv.exe
./mapconv convert --input level.vmf --output level.t3d \
    --profile source1-to-unreal3
./mapconv inspect --input level.t3d
./mapconv validate --input level.t3d
make test
```

## CLI

```text
mapconv convert  --input <file> --output <file> [options]
mapconv inspect  --input <file> [--from <format>]
mapconv validate --input <file> [--from <format>]
mapconv --version
```

| Option | Meaning |
| --- | --- |
| `--from vmf|t3d` | override the input format (otherwise detected by extension, then by content) |
| `--to vmf|t3d` | override the output format (otherwise detected from the output path) |
| `--profile <name>` | entity mapping profile: `default`, `source1-to-unreal3`, `unreal3-to-source1` |
| `--report <file>` | write the diagnostic report to a file as well as stderr |
| `--quiet` | print only errors |
| `--no-materials` | skip the per-material notes |

Exit codes: `0` success (warnings allowed), `1` the conversion produced errors and
no output was written, `2` usage or I/O error.

`inspect` prints the IR summary: format and variant, coordinate system, brush and
face counts, authored vs derived windings, entity classes, materials, bounds and
preserved extensions. `validate` imports the map and runs the structural checks
(degenerate planes, brushes with too few faces, non-finite data, non-convex
brushes, missing materials) without writing anything.

## Supported formats

| Format | Import | Export | Notes |
| --- | --- | --- | --- |
| Source 1 VMF (`.vmf`, format 100) | yes | yes | solids, sides, planes, texture axes, entity key/values, editor and unknown blocks preserved |
| Unreal Engine 3 T3D (`.t3d`) | yes | yes | actors, brushes, polygons, surface flags, materials, unknown properties preserved |
| GoldSrc `.map`, Valve 220 | no | no | format identifiers reserved; no adapter yet |
| Source 2, other engines | no | no | separate research |

## What is implemented

- `geom`: vectors, matrices, planes, windings, half-space clipping, brush face
  evaluation, tolerances, deterministic numeric formatting.
- `ir`: canonical document, brushes, faces with authored/derived windings,
  texture projections, entities, materials, opaque extensions, typed properties.
- `xform`: declared coordinate systems (Source 1, Unreal Engine 3), unit scales,
  plane/winding/entity/texture-projection transforms with mirroring handled
  explicitly.
- `diag`: three severities, stable namespaced codes, deterministic reports.
- `profile`: entity class mapping tables, data-driven and replaceable.
- `vmf` / `t3d`: tokenizers, importers, exporters.
- `convert`: orchestration, entity mapping, validation, fidelity reporting,
  `inspect` summaries.

## Fidelity

Bidirectional does not mean lossless. Current, documented behaviour:

| Situation | Behaviour |
| --- | --- |
| Source units -> Unreal units | exact `1 in = 2.54 cm` scaling plus a Y mirror; reported as `convert.transform` |
| Entity classes | mapped only through a profile; unmapped classes are kept and warned about |
| Entity rotation | yaw/roll sign follows the handedness change; the rest is reported as approximated |
| Source VMF faces | have no vertices; T3D export derives polygon vertices by clipping the brush planes |
| Unreal subtractive brushes | VMF cannot express them; export warns and writes additive geometry |
| Materials | kept by name; no asset or material graph is converted |
| Displacements, overlays, instances | detected and preserved opaquely or reported; never silently dropped |
| T3D nested objects, foliage, MapPackage | reported; not converted |
| Unknown properties | preserved verbatim with their original text |

## Architecture

```text
A.vmf  -> vmf importer -> canonical IR -> t3d exporter -> A.t3d
B.t3d  -> t3d importer -> canonical IR -> xform + profile -> vmf exporter -> B.vmf
```

See `docs/architecture.md` for the package boundaries and invariants,
`docs/ir.md` for the data model, `docs/coordinates.md` for the frames and units,
`docs/diagnostics.md` for the diagnostic contract and `docs/formats/` for the
per-format scope. `docs/testing.md` lists what the tests cover and the provenance
of the fixtures.

## Roadmap

Implemented:

- [x] Project conventions, build (`make`) and test infrastructure.
- [x] Adapter interfaces and conversion diagnostics.
- [x] First version of the canonical Map IR.
- [x] Coordinate-system and unit-conversion primitives.
- [x] VMF and T3D parsing and serialization with unknown-data preservation.
- [x] Brush, plane, winding and texture-projection conversion.
- [x] Initial entity mapping through profiles.
- [x] Bidirectional fixtures, validation and conversion reports.

Next, in rough order:

- [ ] Unreal CSG evaluation/reconstruction for subtractive brushes when targeting
      brush-based formats.
- [ ] GoldSrc `.map` / Valve 220 adapter.
- [ ] Entity property mapping (typed value conversion, not just class renames).
- [ ] Material profile tables and resource reference resolution.
- [ ] CLI end-to-end tests and machine-readable (JSON) diagnostics.
- [ ] Review whether the mature IR should become a versioned interchange format.

## Non-goals for now

- Treating Valve 220 as the universal internal model.
- A dedicated converter per format pair.
- Flattening maps into static meshes or triangles during import.
- Native Unreal package parsing (`.upk`/`.udk`) as part of T3D support.
- Claiming behavioural equivalence between similarly named entity classes.

## License

TBD.
