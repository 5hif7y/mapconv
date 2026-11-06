# mapconv

A multi-format, bidirectional map conversion toolkit for game engines and modding
workflows, built around a shared, engine-independent intermediate representation.

**Status: early development.** The Source 1 VMF and BSP adapters, the Unreal
Engine 3 T3D adapter, the UE3 package table reader, the canonical IR, the
coordinate/unit transforms, the diagnostics pipeline and the CLI exist and are
tested. Conversion is *not*
lossless; every approximation is reported. The CLI is not yet a stable contract.

Supported directions today:

```text
Source 1 .vmf  <->  IR  <->  .t3d  Unreal Engine 3
Source 1 .bsp  ->   IR  <->  .t3d  Unreal Engine 3        (BSP is import-only)
UE3 .ccmap     ->  (tables only: inspect/validate)        (payload reader pending)
```

The architecture is format-pair independent: every adapter converts through the
IR, so adding a format adds 2N conversions instead of 1.

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
mapconv extract  --input <file.ccmap> --output <dir>
mapconv --version
```

| Option | Meaning |
| --- | --- |
| `--from vmf|bsp|t3d|ccmap` | override the input format (otherwise detected by extension, then by content) |
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
| Source 1 BSP (`.bsp`, version 20) | yes | no | world brushes reconstructed from the BSP tree, brush entities read from the brush lumps; displacements and baked data reported |
| Unreal Engine 3 T3D (`.t3d`) | yes | yes | actors, brushes, polygons, surface flags, materials, unknown properties preserved |
| CrimeCraft cooked packages (`.ccmap`) | brush volumes + BSP solids + actors | no | summary and tables, `UPolys` brush polygons, convex BSP solids, actors as entities (`StaticMeshActor` -> `prop_static`, lights -> `light` with `_light`), and `extract` writes inline texture mips as DDS; mesh/material assets are not converted |
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
- `kv`: the shared Valve key/value block tree (VMF and the BSP entity lump).
- `ue3` also reads `Texture2D` objects; `mapconv extract` writes their inline
  mips as DDS files and reports the ones streamed into a texture cache.
- `vmf` / `t3d` / `bsp` / `ue3`: format adapters. `bsp` imports compiled Source
  maps by reconstructing brushes from the BSP tree (method of ericw-tools'
  `bsputil --decompile`, see `docs/formats/source-bsp.md`). `ue3` reads the
  header and tables of cooked UE3 packages (`.ccmap`), see
  `docs/formats/ue3-package.md`.
- `convert`: orchestration, entity mapping, validation, fidelity reporting,
  `inspect` summaries.

## Fidelity

Bidirectional does not mean lossless. Current, documented behaviour:

| Situation | Behaviour |
| --- | --- |
| Source units -> Unreal units | exact `1 in = 2.54 cm` scaling plus a Y mirror; reported as `convert.transform` |
| Entity classes | mapped through a profile; unmapped classes are kept and warned about |
| Entity properties | converted by rule tables (light colour/brightness, rotation, names); anything without a rule is reported and dropped |
| Entity rotation | derived from both engines' rotation matrices (pitch/yaw negated, roll preserved), reported as `convert.rotation-mapped` |
| Source VMF faces | have no vertices; T3D export derives polygon vertices by clipping the brush planes |
| Unreal subtractive brushes | VMF cannot express them; export warns and writes additive geometry |
| Materials | kept by name; no asset or material graph is converted |
| Lightmap scale, smoothing groups (VMF) | no T3D field; reported as dropped (`convert.surface-settings-dropped`) |
| Surface flags (T3D) | no VMF field; reported as dropped (`convert.surface-flags-dropped`) |
| Displacements, overlays, instances | detected and preserved opaquely or reported; never silently dropped |
| BSP world geometry | reconstructed from the compiled tree: the mapper's brushes are not in the file |
| BSP baked data (lightmaps, visibility, cubemaps, pakfile textures) | not read |
| T3D nested objects, foliage, MapPackage | reported; not converted |
| Unknown properties | preserved verbatim with their original text |

## Pipelines

```text
CS:S / CSSO .bsp  -> mapconv -> .vmf  -> Hammer + VBSP -> playable Source map
                             \-> .t3d -> UnrealEd import -> cook -> CrimeCraft .ccmap

CrimeCraft .ccmap -> UPolys brush volumes (implemented) -> IR -> .vmf
                    -> level model + actors + static meshes (next)
```

`mapconv` deliberately stops at the editors' text formats for writing: it does not
contain a BSP compiler or an Unreal cooker. Cooking is left to UnrealEd and the
game's own cook pipeline.

## Architecture

```text
A.vmf  -> vmf importer -> canonical IR -> t3d exporter -> A.t3d
B.t3d  -> t3d importer -> canonical IR -> xform + profile -> vmf exporter -> B.vmf
```

See `docs/architecture.md` for the package boundaries and invariants,
`docs/ir.md` for the data model, `docs/coordinates.md` for the frames and units,
`docs/entity-mapping.md` for what happens to classes and properties,
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
- [x] Typed entity property conversion for Source <-> Unreal: light colour and
      brightness, rotation (derived from both engines' matrices), names.
- [x] Bidirectional fixtures, validation and conversion reports.
- [x] Source 1 BSP importer: brush entities from the brush lumps, world geometry
      reconstructed from the BSP tree.
- [x] UE3 cooked package tables (`.ccmap`): summary, names, imports and exports,
      verified against all 218 CrimeCraft map packages.
- [x] UE3 object prelude (net index, tagged properties) and `UPolys` brush
      polygons, verified against real brush volumes.
- [x] CrimeCraft `.ccmap` -> VMF: one world brush per `UPolys`, with planes and
      texture projections; `villyard` yields 361 brushes / 3 199 faces.
- [x] UE3 `UModel` reader: bounds, vectors, points, BSP nodes, surfaces, verts,
      zones and bulk arrays, verified against real level models; polygons are
      resolved through the vertex pool.
- [x] Convex solid reconstruction from the level BSP tree (`UModel::PointCheck`
      semantics), with VMF faces, materials and texture vectors.
- [x] `ULevel` actor list: the `Actors` TTransArray, URL, model and component
      references, with class histograms in `inspect`.
- [x] Actor payloads: the `RF_HasStack` state-frame prelude, then `NetIndex` and
      tagged properties; Location, Rotation, DrawScale and the component's mesh
      reference become `prop_static` entities (`villyard`: 3 915).
- [x] Texture extraction: `Texture2D` mips to DDS (DXT1/3/5, BGRA8, G8, A8),
      with streamed mips reported (EntryLevel: 29 inline of 90).
- [x] Light actors: Brightness and LightColor from the light component become
      Source `light`/`light_spot`/`light_environment` entities with `_light`
      (villyard: 169 lights, EntryLevel: 16).

Next, in rough order:

- [ ] Texture file cache support (`.tfc`) for streamed mips, mesh geometry
      (`StaticMesh` -> models) and UE3 material graphs to Source materials.
- [ ] Unreal CSG evaluation/reconstruction for subtractive brushes when targeting
      brush-based formats.
- [ ] GoldSrc `.map` / Valve 220 adapter.
- [ ] Class-scoped property rules and game-specific entity tables.
- [ ] Entity I/O (Source `target`/`outputs`, Unreal `Event`/`Tag` graphs).
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

MIT. See `LICENSE`.

The BSP world reconstruction is an independent implementation written from the
format description (leaf regions, plane sets, face clipping); ericw-tools'
`bsputil --decompile` is prior art for the technique, not code this project
copied. `docs/formats/source-bsp.md` records that and the format sources used.
