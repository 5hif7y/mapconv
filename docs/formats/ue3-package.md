# Unreal Engine 3 package (`.ccmap`)

CrimeCraft ships its maps as cooked Unreal Engine 3 packages with the `.ccmap`
extension. Internally they are ordinary UE3 packages: a header with a summary,
three index tables, and per-object payloads addressed from the export table.

`mapconv` reads the summary, names, imports and exports in package `ue3`, and
then deserializes the object payloads it needs: actors, models, brushes, brush
polygons, textures and static mesh geometry. Materials are not read yet.

Everything below was verified against **all 218 `.ccmap` files** in the
CrimeCraft install; every one of them is identical in the fields marked
*constant*.

## Constants observed

| Field | Value | Notes |
| --- | --- | --- |
| Tag | `0x9E2A83C1` (`PACKAGE_FILE_TAG`) | little-endian `C1 83 2A 9E` |
| Package version | `576` | engine version, low 16 bits |
| Licensee version | `5` | high 16 bits: `FileVersion = 0x00050240` |
| Engine build | `4701` | the `EngineVersion` field, not the package format |
| Cooked content version | `87` | |
| Compression flags | `0` | |
| Compressed chunks | `0` | all 218 map packages store the header and payload uncompressed |
| Package flags | `0x008A0009` | allow-download, cooked, contains-map, disallow-lazy-loading, require-imports-already-loaded |

The `VER_*` gates that matter for 576 are listed in `ue3.odin`; later versions
parse the additional fields (623 cross-level GUIDs, 767 texture preallocation)
but are not exercised by the game data, so they emit `ue3.unverified-version`.

## Summary layout

`FPackageFileSummary` is serialized in the order below (`UnLinker.cpp:377`).
Offsets are those of `EntryLevel.ccmap` (the largest verified header).

| Offset | Size | Field | Notes |
| --- | --- | --- | --- |
| 0x00 | 4 | `Tag` | `0x9E2A83C1` |
| 0x04 | 4 | `FileVersion` | engine in low 16, licensee in high 16 |
| 0x08 | 4 | `TotalHeaderSize` | offset of the name table: 175 688 |
| 0x0C | var | `FolderName` | FString; `"None"` for cooked maps |
| 0x15 | 4 | `PackageFlags` | `0x008A0009` |
| 0x19 | 4 | `NameCount` | 1 511 |
| 0x1D | 4 | `NameOffset` | 134 |
| 0x21 | 4 | `ExportCount` | 1 711 |
| 0x25 | 4 | `ExportOffset` | 52 368 |
| 0x29 | 4 | `ImportCount` | 309 |
| 0x2D | 4 | `ImportOffset` | 43 716 |
| 0x31 | 4 | `DependsOffset` | 168 844 |
| 0x35 | 16 | `Guid` | four little-endian words |
| 0x45 | 4 | `GenerationCount` | 1 |
| 0x49 | 12×n | `Generations[]` | `{ExportCount, NameCount, NetObjectCount}` |
| 0x55 | 4 | `EngineVersion` | 4 701 |
| 0x59 | 4 | `CookedContentVersion` | 87 |
| 0x5D | 4 | `CompressionFlags` | 0 |
| 0x61 | var | `CompressedChunks[]` | `INT` count then 16-byte records |
| — | 4 | `PackageSource` | |
| — | var | `AdditionalPackagesToCook[]` | `INT` count then FStrings (`EntryLevel_oceanside`) |

Fields added after version 576 (`ImportExportGuidsOffset`, thumbnail table,
`TextureAllocations`) are absent here and are skipped by version gate.

The additional-package array is part of the header: in `EntryLevel.ccmap` it
occupies `0x65..0x85` and the name table starts exactly at `0x86 = 134`.

## Name table

Each entry is:

| Size | Field |
| --- | --- |
| 4 | `StringLen` |
| `StringLen` | ANSI bytes, **including the NUL terminator** |
| 8 | `Flags` (`EObjectFlags`) |

A negative `StringLen` means UTF-16: the absolute value is the number of code
units, each 2 bytes, terminator included. The `ue3` reader supports both.

The 8-byte flags field is not obvious: assuming the 32-bit flags of older UE3
builds misaligns the second name of every package (the first entry still parses
because its flags happen to be zero). The fork's `EObjectFlags` is `QWORD`
(`UnName.h:57`), and reading 8 bytes makes the table end **exactly** at
`NameOffset + table size == ImportOffset` in all 218 packages.

`FName` values inside the tables are 8 bytes: a name index and a number. The
number disambiguates generated names; `FName::ToString` appends `_<number-1>`
when it is not zero.

## Import table

Every import is 28 bytes (`UnLinker.cpp`, `FObjectImport`):

| Size | Field |
| --- | --- |
| 8 | `ClassPackage` (FName) |
| 8 | `ClassName` (FName) |
| 4 | `OuterIndex` (`FPackageIndex`) |
| 8 | `ObjectName` (FName) |

`309 × 28 = 8 652`, and `43 716 + 8 652 = 52 368`, the export offset.

## Export table

Every export is 68 bytes plus a variable-length array:

| Size | Field |
| --- | --- |
| 4 | `ClassIndex` |
| 4 | `SuperIndex` |
| 4 | `OuterIndex` |
| 8 | `ObjectName` (FName) |
| 4 | `ArchetypeIndex` |
| 8 | `ObjectFlags` |
| 4 | `SerialSize` |
| 4 | `SerialOffset` |
| — | *(version < 543)* legacy `TMap<FName, INT>` component map |
| 4 | `ExportFlags` |
| var | `GenerationNetObjectCount[]`: `INT` count + `INT` values |
| 16 | `PackageGuid` |
| 4 | `PackageFlags` |

`1 711 × 68 = 116 348`; the package stores 128 extra bytes of net-object counts,
so the table ends at `52 368 + 116 476 = 168 844 = DependsOffset`.

### `FPackageIndex`

Table references use the UE3 convention:

- `0` — null,
- `> 0` — export index `value - 1`,
- `< 0` — import index `-value - 1`.

Example from `EntryLevel.ccmap`: export 0 has `ClassIndex = -15`, i.e. import
`14`, whose `ObjectName` is `AmbientSound`. Import 0 has `OuterIndex = -207`,
i.e. import `206`, the `Engine` package.

## Verification

The reader self-checks the layout on every file:

- the name table must end exactly at `ImportOffset`,
- the import table must end exactly at `ExportOffset`,
- the export table must end exactly at `DependsOffset`.

A mismatch is reported as `ue3.table-mismatch` with the byte difference. All
218 packages pass with zero diagnostics; `mapconv validate` on the maps listed
in `docs/testing.md` returns `ok: no diagnostics`.

## Object payloads

Every export's `SerialOffset`/`SerialSize` points at a payload with this prelude:

| Size | Field |
| --- | --- |
| 4 | `NetIndex` (`INT`) |
| var | `FPropertyTag` records for properties that differ from the class default |
| 8 | terminator: a tag whose name resolves to `"None"` with number 0 |
| var | native class data |

`FPropertyTag` for version 576 (`Core/Inc/UnPropertyTag.h`):

| Size | Field |
| --- | --- |
| 8 | `Name` (FName) |
| 8 | `Type` (FName, e.g. `BoolProperty`) |
| 4 | `Size` |
| 4 | `ArrayIndex` |
| 8 | `StructName` only when `Type == "StructProperty"` |
| 4 | boolean value only when `Type == "BoolProperty"` (before gate 673) |
| — | `EnumName` only when `Type == "ByteProperty"` and version ≥ 633 |
| `Size` | property value |

Two details that cost time to discover:

- The terminator is identified by the **name string** `"None"`, not by name
  index 0. Cooked packages reorder the name table (`EntryLevel` has `BookMark` at
  135 and `None` at 936; `transient_map` has `None` at 32), so an index-based
  check misses it and the tag walk derails.
- `BoolProperty` carries its value inside the tag and has `Size == 0`; the other
  types carry `Size` bytes of value afterwards.

### UPolys: brush polygons

Brush volumes (`BlockingVolume` and subclasses) own two objects: a `Model` and a
`UPolys`. The `UPolys` body is the authoring geometry of the brush:

| Size | Field |
| --- | --- |
| 4 | `Num` |
| 4 | `Max` |
| 4 | `Owner` (`FPackageIndex`, points back at the `UPolys` export) |
| var | `Num` × `FPoly` |

`FPoly` for version 576 (`Engine/Src/UnModel.cpp`, `Engine/Inc/UnObj.h`):

| Size | Field |
| --- | --- |
| 12 | `Base` (FVector) |
| 12 | `Normal` |
| 12 | `TextureU` |
| 12 | `TextureV` |
| 4 + 12 × n | `Vertices` (`INT` count + `FVector` each) |
| 4 | `PolyFlags` |
| 4 | `Actor` (`FPackageIndex`) |
| 8 | `ItemName` (FName) |
| 4 | `Material` (`FPackageIndex`) |
| 4 | `iLink` |
| 4 | `iBrushPoly` |
| 4 | `ShadowMapScale` (float) |
| 4 | `LightingChannels` |

`LightmassSettings` (version ≥ 600) and the rule-set pointer/variation name
(≥ 606 / ≥ 670) are absent in 576 and are not read.

`FPoly.Base` is stored in **brush-local space** and keeps the brush's creation
size: in `villyard` the largest `|Base|` is 1024 while the winding vertices reach
6144 after scaling. The winding is world space and agrees with `Normal`
(`FPoly::CalcNormal` uses the same cross-product convention), so the plane
distance must be taken from a winding vertex, not from `Base`. Texture offsets
anchored at `Base` are approximate until the owning actor's transform is
converted.

Verification: all 368 `UPolys` objects in `EntryLevel`, `villyard`,
`City05_HQ` and `City_Bau` parse exactly to their declared `SerialSize`
(`villyard` alone: 3 199 polygons, 14 726 vertices). A size mismatch is
reported as `ue3.polys-size-mismatch`, which is how a wrong `FPoly` layout
would surface.

`mapconv inspect` prints the totals ("brush polys: 362 UPolys object(s) …") and
`mapconv convert --input map.ccmap --output map.vmf` emits one world brush per
`UPolys` object (villyard: 361 brushes, 3199 faces, 1.1 MB VMF in 0.4 s).

## UModel: the BSP level model

`UModel::Serialize` (`Engine/Src/UnModel.cpp`) writes the level's BSP tree and
the polygons of every node. The layout below was verified byte for byte: the
level models of `EntryLevel` (2 716 B) and `transient_map` (3 364 B) and every
brush model of `villyard` parse exactly to their declared `SerialSize`.

| Field | Encoding |
| --- | --- |
| `Bounds` | `FBoxSphereBounds`: origin (3 f32), box extent (3 f32), sphere radius (f32) = 28 B |
| `Vectors` | bulk: element size 12, count, `FVector[count]` |
| `Points` | bulk: element size 12, count, `FVector[count]` |
| `Nodes` | bulk: element size 64, count, `FBspNode[count]` |
| `Surfs` | **TTransArray**: owner reference (4 B), count, `FBspSurf[count]` (56 B each) |
| `Verts` | bulk: element size 24 (16 when cooked for a console), count, `FVert[count]` |
| `NumSharedSides`, `NumZones` | 2 × i32 |
| `Zones` | `FZoneProperties[NumZones]`, 24 B each |
| `Polys` | object reference (4 B) |
| `LeafHulls`, `Leaves` | bulk arrays |
| `RootOutside`, `Linked` | 2 × i32 |
| `PortalNodes` | bulk array |
| legacy shadow edges | bulk array, present before version 686 |
| `NumUniqueVertices` | i32 |
| `VertexBuffer` | bulk: element size 36, `FModelVertex[count]` |

Two quirks cost time and are easy to trip over:

- **`Surfs` is a `TTransArray`**, whose `operator<<` writes the array *owner*
  before the count. Without those 4 bytes the surface count reads as `803`
  (the owner index) and every following field is shifted.
- **Bulk arrays write the element size first**, then the count, then the data.
  For packages older than the engine build (all of them: 576 vs 10897) the
  elements are written field by field, so the element size is a struct size and
  the data must be decoded with the same field order (`FBspNode` is 64 B,
  `FVert` 24 B on PC).

`FBspNode` exposes the polygon: `Plane`, `iVertPool` and `NumVertices` index the
vertex pool (`Verts`), each `FVert.pVertex` indexes `Points`, and `iSurf` gives
the material, flags and texture vectors. `model_polygons` resolves that chain;
`mapconv inspect` reports the totals ("bsp models: 2 model(s), 6 node(s), …").

Reconstructing **convex solids** from the node tree is implemented in
`model_solids`, following `UModel::PointCheck`: a leaf reached with
`outside == false` is solid, and its accumulated half-spaces bound it. The brush
convention uses `dot(p, n) <= dist`, so the node's front region is bounded by the
flipped plane and the back region by the plane as stored. Planes become faces
through `geom.brush_face_winding`, with material and texture vectors taken from
the node's surface (`pBase` indexes `Points`, so the projection is exact).

`mapconv convert` uses the level BSP solids only when the level model's `Polys`
is empty; otherwise the `UPolys` brushes already carry the geometry and adding
the BSP would duplicate it (villyard: 22 solid regions, 188 faces, added to 361
`UPolys` brushes).

## ULevel: actors and level references

`ULevelBase::Serialize` writes, after the shared object prelude:

| Field | Encoding |
| --- | --- |
| `Actors` | **TTransArray**: owner reference (4 B), count, package indices (4 B each) |
| `URL` | five FStrings (`Protocol`, `Host`, `Map`, `Portal`, `Op`), port (i32), valid (i32) |

and `ULevel::Serialize` continues with:

| Field | Encoding |
| --- | --- |
| `Model` | object reference |
| `ModelComponents` | plain `TArray`: count + references (no owner) |
| `GameSequences` | plain `TArray`: count + references (no owner) |

Missing the `Actors` owner reference (as with `Surfs`) shifts the URL and every
following field. Verified on four maps: `EntryLevel` 89 actors, `villyard`
4 604 (3 966 `StaticMeshActor`, 358 `BlockingVolume`, 170 `PointLight`),
`City_Bau` 1 403, `transient_map` 5 (two real actors and three null slots left
by editor-only actors removed during cooking). `inspect` prints the class
histogram.

### Actor payload prelude: the state frame

An actor's payload does **not** start with the tagged properties. `UObject::Serialize`
writes the execution stack first when the object has `RF_HasStack` (every actor
does), and only then the `NetIndex` and the tags. That is the class-dependent
prefix seen before the tag stream: 26 bytes for an actor with a script state
(`PointLight`, `StaticMeshActor`), 22 for one without (`BlockingVolume`), plus
4 for the `NetIndex`. Assets without a stack start at the `NetIndex` (4 bytes),
and components write `UComponent::PreSerialize`'s template owner class (4 bytes,
plus an `FName` for template objects) before everything else.

`FStateFrame` for version 576:

| Size | Field |
| --- | --- |
| 4 | `Node` (object reference) |
| 4 | `StateNode` (object reference) |
| 8 | `ProbeMask` (QWORD; before gate 691) |
| 2 | `LatentAction` (WORD from gate 566; `INT` before) |
| 4 + 12 × n | `StateStack`: count, then `FPushedState` = `State` (4) + `Node` (4) + `Offset` (4) |
| 4 | `Code` offset into `Node`'s script, only when `Node` is not null |

Confirmed with engine probes on `transient_map`: `ULinkerLoad::Preload` reports
`Tell() == SerialOffset` for every export; inside `UObject::Serialize` the
`NetIndex` starts 26 bytes later for `PlayerStart`/`WorldInfo` and the tags end
exactly at `SerialOffset + SerialSize` (PlayerStart: net 4 bytes, properties
300 bytes, total 330).

With the prelude handled, actor properties are readable: `Location` (Vector,
12 B), `Rotation` (Rotator, three 32-bit angle units), `DrawScale` (float) and
the component reference. The component's `StaticMesh`/`SkeletalMesh` property
resolves the mesh name, and its `Brightness` (float) and `LightColor` (`FColor`,
four bytes stored B, G, R, A) feed lights. `mapconv` turns a `StaticMeshActor`
into a `prop_static` entity with `origin`, `angles` and `model` (villyard:
3 915), and light actors into `light`/`light_spot`/`light_environment` with
`_light` built from colour and brightness (EntryLevel: 16 lights).

## Texture2D: mip data and DDS export

`UTexture2D::Serialize` writes `UTexture`'s data (`SourceArt`, a bulk record),
then the mip array. Each `FTexture2DMipMap` is a bulk-data record followed by
`SizeX` and `SizeY`:

| Field | Encoding |
| --- | --- |
| `SourceArt` | bulk record: flags (u32), element count, size, offset |
| mip count | i32 |
| each mip | bulk record, then `SizeX` (i32), `SizeY` (i32) |

A bulk record is `flags, count, size, offset`; when `BULKDATA_StoreInSeparateFile`
(bit 0) is clear the payload follows the 16-byte header at `offset == Tell()`.
Texture properties (`SizeX`, `SizeY`, `Format`, `TextureFileCacheName`) come from
the normal tag stream; `Format` is a `ByteProperty` whose value is an `FName`
such as `PF_DXT5`.

When bit 0 is set the mip lives in a **texture file cache** (`.tfc`), which the
map package does not contain; the mip is reported with its cache name, offset and
size. CrimeCraft maps mix both: in `EntryLevel`, 29 of 90 textures have inline
mips and the rest stream the largest mips while the small ones stay inline.

`mapconv extract --input map.ccmap --output dir` writes the leading inline mips
of each texture as `<name>.dds` (DXT1/3/5, BGRA8, G8, A8) and reports the
streamed ones. The DDS header follows the classic 124-byte layout with a 32-byte
pixel-format block.

## What is not implemented yet

- **Native bodies of other classes.** `ULevel`, `UWorld` and `UModel` start
  with native fields whose layout (BSP nodes/surfs/verts, actor arrays) is not
  implemented yet; only the shared prelude and `UPolys` are read.
- **Streamed texture mips.** Mips in a `.tfc` are not decoded; the cache file is
  not part of the map package. Inline mips are exported as DDS.
- **Mesh assets and materials.** Actor transforms, mesh references and texture
  images are read, but mesh geometry and material graphs are not converted; the
  VMF keeps the Unreal asset names.
- **BSP solids.** Node polygons are readable, but turning the node tree into
  convex brushes (the way the Source decompiler does) is not implemented; only
  `UPolys` brush volumes are converted today.
- **Compressed chunks.** None of the map packages use them. The summary fields
  and the three codecs (`COMPRESS_ZLIB 1`, `COMPRESS_LZO 2`, `COMPRESS_LZX 4`)
  are surfaced, but payload decompression is not implemented.
- **Versions above 576.** The conditional fields are parsed, but only 576/5 has
  game data behind it.

## References

- `Development/Src/Core/Src/UnLinker.cpp` — `FPackageFileSummary` operator,
  `FObjectImport`, `FObjectExport`, `FCompressedChunk`, `FGenerationInfo`.
- `Development/Src/Core/Src/UnName.cpp:983` — `FNameEntry` serialization.
- `Development/Src/Core/Inc/UnObjVer.h` — version gates.
- `Development/Src/Core/Inc/UnObjBas.h` — `EPackageFlags`.
- Package `ue3` in this repository; tests in `ue3/ue3_test.odin` build a
  synthetic 576/5 package byte by byte.

## StaticMesh geometry

`UStaticMesh::Serialize` at version 576 takes every legacy branch: the compact
kDOP tree (770), source data (823), mesh proxies (859) and separate vertex color
(801) are all newer than the package. Each LOD still carries the interleaved
tangent/UV/color buffer and the shadow extrusion buffer, and its position buffer
contains the cloned shadow-volume vertices that `RemoveLegacyShadowVolumeVertices`
trims on load.

The layout below was verified byte for byte against `EngineMeshes.ccpak`
(BackgroundCube 138 vertices / 204 triangles, Cube 24 / 12, Sphere 323 / 528) and
against the meshes embedded in `instance/city01_FFA.ccmap` (three LODs).

```text
body
  Bounds                    28   FBoxSphereBounds
  BodySetup                  4   FPackageIndex
  legacy kDOP tree               bulk nodes (32 B) + bulk triangles (8 B)
  InternalVersion            4   18
  legacy content tags        4 + 8n   only when version < 593
  LODModels                  4 + n × FStaticMeshRenderData
  LODInfo                    4   elements write no payload (editor-only)
  LODDistanceRatio … ThumbnailDistance  24

FStaticMeshRenderData
  RawTriangles               flags, count, size, offset; inline 272 B/element
  Elements                   count + (36 B + 8·fragments)/element
  PositionVertexBuffer       stride (12), count, bulk (12)
  LegacyVertexBuffer         NumTexCoords, stride, count, bUseFullPrecisionUVs,
                             bulk (stride)
  LegacyExtrusionBuffer      stride, count, bulk (stride)
  NumVertices                4   real count, excludes shadow clones
  IndexBuffer                bulk of 16-bit indices (element size 2)
  WireframeIndexBuffer       bulk of 16-bit indices
  LegacyEdges                bulk of FMeshEdge (16 B)
  LegacyShadowDoubleSided    count + bytes
```

`Elements` holds `Material` (FPackageIndex), three collision/shadow flags, the
index range, the vertex range, the material override index and the fragment
ranges. `RawTriangles` elements are `FStaticMeshTriangle` at 272 bytes: three
vertex indices, 8 UV sets, three colors, material/fragment/smoothing bookkeeping
and the overridden tangent basis.

Geometry extraction uses the position and index buffers, not `RawTriangles`
(cooked meshes ship it empty): positions `[0, NumVertices)`, indices as one-based
`f` records in OBJ. Both stay in Unreal coordinates (X forward, Y right, Z up);
`xform` is the place for axis conversion.

The reader refuses packages at or above `VER_REMOVED_SHADOW_VOLUMES` (686)
instead of silently misreading a newer buffer layout.
