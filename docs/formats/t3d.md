# Unreal Engine 3 T3D adapter

The `t3d` package reads and writes the UnrealEd text interchange format. It is
**not** a package reader: `.upk`, `.udk` and `.u` files are out of scope.

The syntax implemented here follows the engine's own exporters,
`Development/Src/UnrealEd/Src/UnEdExp.cpp` in this workspace:

- `ULevelExporterT3D::ExportText` — `Begin Map` / `Begin Level NAME=` /
  `Begin Actor Class= Name= Archetype=` / `Begin Surface` / `End Map`;
- `UPolysExporterT3D::ExportText` — `Begin PolyList`, `Begin Polygon Item=
  Texture= Flags= Link= ShadowMapScale= LightingChannels=`, `Origin`, `Normal`,
  `TextureU`, `TextureV`, `Vertex`, `End Polygon`;
- `UModelExporterT3D::ExportText` — `Begin Brush Name=` wrapping the poly list;
- `UObjectExporterT3D::ExportText` — `Begin Object ... End Object` for nested
  objects (not mapped);
- `FPoly::CalcNormal` (`UnFPoly.cpp`) — the vertex order convention;
- `ECsgOper` (`EngineClasses.h`) — `CSG_Active 0`, `CSG_Add 1`, `CSG_Subtract 2`,
  `CSG_Intersect 3`, `CSG_Deintersect 4`.

Unreal's `SetFVECTOR` writes vectors as `%+013.6f,%+013.6f,%+013.6f`; the exporter
reproduces that shape (`+0128.000000,...`) so the output matches what UnrealEd
itself would write. `ue_precision` can be switched off for compact output.

## Supported constructs

| Construct | Import | Export |
| --- | --- | --- |
| `Begin Map [Name=]` | map name in metadata | written |
| `Begin MapPackage` | marked as an extension, warning | not written |
| `Begin Level [NAME=]` | level name -> world id | written as `NAME=` or `Level` |
| `Begin Actor Class= Name= Archetype=` | entity, class, id, archetype | written |
| actor properties (`Location=`, `Rotation=`, `CsgOper=`, ...) | typed where recognised, raw preserved | written |
| `Begin Brush Name=` | brush, id | written |
| `Begin PolyList` / `Begin Polygon` | faces | written |
| `Polygon` attributes `Item=`, `Texture=`, `Flags=`, `Link=`, `ShadowMapScale=`, `LightingChannels=` | `t3d.*` face properties + typed `flags`/`lightmap_scale` | written back from those properties |
| `Origin`, `Normal`, `TextureU`, `TextureV`, `Vertex` | plane, winding, texture projection | written |
| `Begin Surface` | noted, not geometry | empty section written |
| nested `Begin Object` | marker + warning | not written |
| `Begin Foliage` | marker + warning | not written |

## Geometry rules

- The plane goes through the polygon vertices: `dist = dot(normal, Vertex[0])`.
  `Origin` is `FPoly::Base`, the texture projection origin, and is **not**
  guaranteed to lie on the polygon.
- `TextureU`/`TextureV` are texels per world unit; the IR stores them as the
  projection linear part with `u_offset = -dot(Origin, TextureU)`.
- Vertex order is checked, not assumed: the importer orients every winding
  counter-clockwise around the polygon normal, and the exporter emits the IR
  winding as-is (Unreal's `CalcNormal` uses the same cross-product convention).
- A brush with fewer than four polygons is reported; it is still imported so the
  data is not lost.

## Not supported

| Feature | Behaviour |
| --- | --- |
| native packages (`.upk`, `.udk`, `.u`) | out of scope |
| `Begin MapPackage` contents | preserved as a marker, reported, not converted |
| nested `Begin Object` subobjects/components | reported, dropped on export |
| foliage instances | reported, dropped |
| terrain (`ATerrain` exporter) | reported as an unknown actor block |
| UnrealScript (`.uc`) | not a map format; untouched |
| CSG evaluation | the exporter writes authored brushes; subtractive brushes are a VMF limitation, not evaluated |
| asset/material resolution | material paths kept as text |

## Fixtures

`tests/fixtures/unreal/cube.t3d` is authored for this repository: one brush actor
with a six-polygon cube of ±128 units, one `PointLight` with `Location` and
`Rotation`, one material, `Flags=1` on every polygon. Provenance: written by hand
from the exporter grammar above; redistributable with the project.
