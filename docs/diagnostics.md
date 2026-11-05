# Diagnostics

Every conversion decision that loses, approximates or preserves something out of
the ordinary produces a diagnostic. Codes are stable, lowercase and namespaced by
the component that raises them, so tooling can filter on them.

## Severity

| Severity | Meaning | Effect on exit code |
| --- | --- | --- |
| `error` | the output would be invalid, or the conversion cannot continue safely | `mapconv` exits `1` and writes no output |
| `warning` | data was approximated, omitted, or may behave differently | exit `0` |
| `info` | a decision, a preserved extension, or a non-problematic transformation | exit `0` |

Diagnostics carry the affected object when the adapter knows it (brush id,
entity id, `world.solid[3].side[2]`) and a source location for parsed text.

## Codes

### `io.*`

| Code | Meaning |
| --- | --- |
| `io.format-sniffed` | the format was detected from content because the extension was not decisive |

### `vmf.*`

| Code | Meaning |
| --- | --- |
| `vmf.empty` | no blocks at all; not a VMF file |
| `vmf.dangling-word` | bare word without a block or value |
| `vmf.key-without-value` | `"key"` not followed by a value |
| `vmf.unclosed-block` | a block reaches end of file without `}` |
| `vmf.no-versioninfo` | missing `versioninfo`; format 100 assumed |
| `vmf.no-formatversion` | `versioninfo` has no `formatversion` |
| `vmf.preserved-block` | top-level block preserved as an opaque extension |
| `vmf.unknown-block` | unknown top-level block preserved opaquely |
| `vmf.unknown-world-block` | unknown `world` child preserved opaquely |
| `vmf.entity-without-classname` | entity has no `classname` |
| `vmf.instance` | `func_instance` preserved but not resolved |
| `vmf.preserved-connections` | entity I/O kept as an opaque extension |
| `vmf.unknown-entity-block` | unknown entity child preserved opaquely |
| `vmf.unsupported-solid-block` | `dispinfo`/`hidden`/`group` detected, not interpreted |
| `vmf.side-without-plane` | side has no `plane` |
| `vmf.invalid-plane` | plane is not three valid points |
| `vmf.invalid-uaxis`, `vmf.invalid-vaxis` | texture axis is malformed |
| `vmf.degenerate-solid` | fewer than four sides |
| `vmf.face-clipped-away` | a face does not survive clipping against its own brush |
| `vmf.csg-op-unsupported` | target cannot express the brush's CSG operation |
| `vmf.face-without-material` | face has no material; `TOOLS/TOOLSNODRAW` is written |
| `vmf.second-worldspawn` | a second `worldspawn` entity is written as a normal entity |
| `vmf.dangling-brush` | entity references a brush index that does not exist |
| `vmf.foreign-surface-data` | source-format surface attributes had no VMF spelling |

### `t3d.*`

| Code | Meaning |
| --- | --- |
| `t3d.empty` | no blocks; not a T3D file |
| `t3d.no-map` | no `Begin Map` |
| `t3d.begin-without-keyword` | `Begin` without a block keyword |
| `t3d.unexpected-end` | `End` without a matching `Begin` |
| `t3d.mismatched-end` | `End X` closes `Begin Y` |
| `t3d.unclosed-block` | file ends inside an open block |
| `t3d.data-outside-block` | property line outside any block |
| `t3d.map-package` | `Begin MapPackage` holds native package data and is not converted |
| `t3d.surface-section` | the clipboard `Begin Surface` section is not map geometry |
| `t3d.fragment` | polygon list outside a map imported as a world brush |
| `t3d.unknown-root-block`, `t3d.unknown-map-block`, `t3d.unknown-level-block`, `t3d.unknown-actor-block`, `t3d.unknown-brush-block`, `t3d.unknown-polylist-block` | unknown block, preserved as a marker |
| `t3d.actor-without-class` | actor without `Class=` cannot be mapped |
| `t3d.invalid-location` | `Location` is not a vector |
| `t3d.nested-object` | nested `Begin Object` data is not mapped |
| `t3d.foliage` | foliage instances are not converted |
| `t3d.polygon-too-few-vertices` | polygon has fewer than three vertices |
| `t3d.invalid-vertex` | vertex is not a vector |
| `t3d.missing-normal` | normal derived from the vertices |
| `t3d.degenerate-polygon` | neither a normal nor a winding could be derived |
| `t3d.missing-texture-axes` | polygon has no `TextureU`/`TextureV` |
| `t3d.polygon-without-texture` | polygon has no `Texture=` |
| `t3d.unknown-polygon-data` | unknown polygon data line preserved |
| `t3d.degenerate-brush` | fewer than four polygons |
| `t3d.face-without-winding` | face collapses when evaluated; polygon skipped |
| `t3d.winding-derived` | polygon vertices were derived from brush planes |
| `t3d.brush-without-faces` | brush has no polygons |
| `t3d.dangling-brush`, `t3d.second-worldspawn` | referential problems on export |
| `t3d.foreign-surface-data` | source-format surface attributes had no T3D spelling |

### `kv.*`

| Code | Meaning |
| --- | --- |
| `kv.dangling-word` | bare word without a block or value |
| `kv.key-without-value` | quoted key not followed by a value |
| `kv.unclosed-block` | a block reaches end of input without `}` |

### `bsp.*`

| Code | Meaning |
| --- | --- |
| `bsp.too-short`, `bsp.bad-ident`, `bsp.unsupported-version` | the file is not a Source 1 BSP version 19/20 |
| `bsp.lump-out-of-range` | a lump points outside the file and was skipped |
| `bsp.header` | summary of the parsed lumps |
| `bsp.no-entities`, `bsp.no-worldspawn`, `bsp.no-models`, `bsp.invalid-headnode` | the map cannot be attributed or decompiled |
| `bsp.entity-without-class` | entity lump record without `classname` |
| `bsp.asset-model-reference` | an entity's `model` is an asset path, not a `*N` brush model |
| `bsp.invalid-brush` | brush index out of range |
| `bsp.leafs-skipped` | solid leaves that produced no valid brush |
| `bsp.side-texture-approximated` | a reconstructed side had several textures; the largest face's material was kept |
| `bsp.displacements` | displacement surfaces present; base surfaces exported |

### `convert.*`

| Code | Meaning |
| --- | --- |
| `convert.unsupported-source`, `convert.unsupported-target` | no adapter for that format |
| `convert.transform` | the frame/unit transform that was applied |
| `convert.degenerate-plane` | a plane collapses under the transform |
| `convert.degenerate-texture-axis` | a texture projection collapses under the transform |
| `convert.unknown-profile` | requested profile does not exist; no mapping applied |
| `convert.unmapped-class` | no profile entry for an entity class; the class name is kept |
| `convert.class-mapped` | class renamed by the profile (with the profile's note) |
| `convert.class-without-actor` | class has no target equivalent and no geometry |
| `convert.entity-collapsed` | geometry-only actor; its brushes moved to the world |
| `convert.property-mapped` | property converted to the target key |
| `convert.property-dropped` | property intentionally dropped (with the reason) |
| `convert.property-unmapped` | no rule for a property; it was dropped |
| `convert.rotation-mapped` | angles/rotator converted, with both representations |
| `convert.angles-invalid` | `angles` could not be parsed |
| `convert.light-mapped`, `convert.light-brightness-scaled` | light colour/brightness mapped, with the scale that was applied |
| `convert.light-value-invalid`, `convert.light-color-invalid`, `convert.light-brightness-invalid` | light property could not be parsed |
| `convert.asset-reference` | asset reference preserved as text only; no asset converted |
| `convert.surface-settings-dropped` | lightmap scale / smoothing groups had no target field |
| `convert.surface-flags-dropped` | surface flags had no target field |
| `convert.material-preserved` | material kept by name, no asset converted |
| `convert.summary` | object counts of the finished conversion |

### `validate.*`

| Code | Meaning |
| --- | --- |
| `validate.empty-map` | no geometry and no entities |
| `validate.brush-too-few-faces` | a convex solid needs at least four faces |
| `validate.degenerate-plane` | plane normal has zero length |
| `validate.non-finite-plane`, `validate.non-finite-origin` | NaN or infinity in authored data |
| `validate.face-without-material` | face has no material |
| `validate.degenerate-winding` | authored polygon has no area |
| `validate.non-convex-brush` | authored vertices fall outside a face plane |
| `validate.entity-without-class` | entity has no class name |

## Reporting

`mapconv convert` prints all diagnostics to stderr, in the order they were raised,
and `--report <file>` writes the same text to a file. The report is deterministic
so it can be diffed between runs.
