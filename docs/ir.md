# Canonical Map IR

The IR (`ir` package) is engine-independent. It stores what the source authored
plus explicit slots for engine-specific data; it does not adopt any single
engine's model.

## Document

| Field | Contents | Provenance |
| --- | --- | --- |
| `metadata.format` | `Source_VMF`, `Unreal_T3D`, future values | importer |
| `metadata.variant` | `"vmf/100"`, `"t3d/ue3"`, `"vmf/unknown"` | version block, if present |
| `metadata.source_path` | path handed to the importer | CLI |
| `metadata.generator` | `mapconv <version>` | build constant |
| `metadata.props` | format-level key/values (`mapversion`, `editorversion`, `map_name`) | importer, unknown-safe |
| `cs` | the `xform.CoordinateSystem` the numbers are expressed in | importer |
| `brushes` | flat brush pool, referenced by index | importer |
| `world` | the world entity (`worldspawn`); owns world geometry | importer |
| `entities` | every non-world entity | importer |
| `materials` | material names encountered, deduplicated | importer |
| `resources` | external references that are not converted | importer (currently unused by VMF/T3D) |
| `extensions` | opaque blocks preserved from the source | importer |

## Brush

| Field | Contents | Notes |
| --- | --- | --- |
| `id` | source identifier as text | stable across round trips when numeric |
| `op` | `Csg_Op`: `Add`, `Subtract`, `Intersect`, `Deintersect`, `Replace` | authoring operation, not evaluated |
| `faces` | planar sides | see below |
| `props` | brush-level key/values | preserved verbatim |
| `extensions` | opaque brush blocks (`editor`, unknown blocks) | written back by the same adapter |

A brush is always a convex solid. `validate` reports brushes with fewer than four
faces and brushes whose authored vertices fall outside a face plane. There is
no implicit convex decomposition: it would be a separate, explicit operation.

## Face

| Field | Contents | Notes |
| --- | --- | --- |
| `plane` | `normal` (unit) and `dist` (`dot(normal, p) = dist`) | normal points away from the solid |
| `winding` | polygon vertices, counter-clockwise around `plane.normal` | evaluated geometry |
| `winding_source` | `Authored` (explicit vertices) or `Derived` (clipped from planes) | provenance of the winding |
| `uv` | world-to-texel projection | see below |
| `material` | material path as authored | no asset is resolved |
| `flags` | native surface flags, `0` when absent | T3D `Flags=`, VMF has none |
| `lightmap_scale` | VMF `lightmapscale`, T3D `ShadowMapScale` | numeric value only |
| `smoothing_groups` | VMF `smoothing_groups` | `0` when absent |
| `props` | unknown surface attributes | keys are namespaced by origin: `vmf.*`, `t3d.*` |
| `extensions` | opaque blocks | preserved verbatim |

Windings are **derived data**. A VMF face only carries a plane, so its winding is
clipped from the brush's planes and marked `Derived`. A T3D polygon carries
explicit vertices and is marked `Authored`. Exports that need vertices (T3D)
re-derive them when the winding is missing; exports that need planes (VMF) ignore
the winding except to pick three points that reproduce the plane.

## Texture projection

`TexProjection` is the world-to-texel map:

```text
texel_u = dot(position, uv.u) / uv.u_scale + uv.u_offset
texel_v = dot(position, uv.v) / uv.v_scale + uv.v_offset
```

- VMF import: `u` is the `uaxis` vector, `u_scale` its scale, `u_offset` its shift.
- T3D import: `u` is `TextureU`, `u_scale = 1`, `u_offset = -dot(Origin, TextureU)`.
- `rotation` only preserves the authored VMF value for re-serialization.

`u_scale`/`v_scale` are kept *only* so a VMF to VMF pass stays textually stable;
the mapping itself is fully carried by `u`, `v` and the offsets. Texture
projections transform as covectors (`xform.apply_tex_projection`), which keeps the
texel value of a physical surface point identical across a unit or handedness
change.

## Entity

| Field | Contents | Notes |
| --- | --- | --- |
| `id` | source identifier/name | may be empty |
| `class_name` | native class name (`light`, `PointLight`, ...) | mapped only by a profile |
| `origin` | position in the document frame | typed, also kept in `props` |
| `angles` | VMF `angles` (pitch yaw roll), zero when absent | not interpreted |
| `rotation` | T3D `Rotation` struct | `has_rotation` marks presence |
| `props` | all entity key/values, typed where recognised | `raw` keeps the source text |
| `brushes` | indices into `Document.brushes` | brush entities keep their solids |
| `children` / `parent` | hierarchy indices | reserved; T3D nested objects are not yet mapped |
| `extensions` | opaque blocks (`connections`, ignored children) | preserved |

## Property values

`Value` is a union of `string`, `f64`, `i64`, `bool`, `geom.Vec3`, `Rotation`,
`Struct_Value`, `Array_Value` and `Raw`. Every `Property` also keeps `raw`, the
exact source text, so unknown or partially understood values can be written back
without inventing semantics.

## Materials and resources

`Material.name` is the authored reference: a VMF material path (`DEV/...`) or an
Unreal object path (`EngineMaterials.DefaultMaterial`). No mapping is applied by
default; `convert` reports each material once as preserved-by-name. Asset
conversion and resource resolution are explicit non-goals for now.

## Extensions

`Extension{name, data}` stores blocks the current IR does not interpret
(`visgroups`, `viewsettings`, `editor`, T3D `MapPackage` markers). Adapters write
them back when converting to the same format and report them when dropped.

## Format identity

`ir.Format` enumerates the formats the toolkit knows about. `Goldsrc_MAP` and
`Valve_220` are declared but have no adapter yet; `convert` rejects them with
`convert.unsupported-source` / `convert.unsupported-target`.
