# Source 1 VMF adapter

The `vmf` package imports and exports the Valve Map Format text format targeted at
Source 1 (format version 100). It is a real tokenizer plus block tree, not a line
scanner, so indentation, key order and escapes do not matter.

## Supported constructs

| Construct | Import | Export |
| --- | --- | --- |
| `versioninfo` | `formatversion`, `editorversion`, `mapversion` -> metadata | written with `formatversion 100` |
| `visgroups`, `viewsettings`, `cameras`, `cordon` | preserved as opaque extensions | written back verbatim |
| `world` | entity `worldspawn`, its properties and solids | written first |
| `entity` | class name, ids, origins, angles, all key/values | written after the world |
| `solid` + `side` | brush + planar faces | written with generated ids |
| `side.plane` | three points -> plane | three points recovered from the face |
| `side.uaxis` / `vaxis` | texture axis, scale, shift -> `TexProjection` | re-emitted from the projection |
| `side.rotation`, `lightmapscale`, `smoothing_groups` | typed face fields | re-emitted |
| `editor` block | opaque extension, written back unchanged | kept |
| unknown side keys | preserved as `vmf.<key>` properties | written back as `<key>` |
| unknown blocks | opaque extension + diagnostic | written back verbatim |

## Plane convention

VMF stores three points per side. The outcrop normal follows the Quake/Valve
convention (verified against `ericw-tools`' `mapface_t::set_planepts`):

```text
normal = normalize(cross(p0 - p1, p2 - p1))
dist   = dot(p1, normal)
```

So the three points are **clockwise** seen from the side the normal points to.
The IR keeps windings counter-clockwise around their own normal, so the exporter
emits the winding reversed (`w2, w1, w0`) and, when no winding exists, three
points from `geom.plane_points`.

## Texture axes

```text
"uaxis" "[x y z shift] scale"
texture_u = dot(position, (x,y,z)) / scale + shift
```

The IR keeps `u = (x,y,z)`, `u_scale = scale`, `u_offset = shift`, so a VMF to VMF
pass re-emits the original numbers. Non-unit axes (produced when importing from
T3D) are valid for the format: the engine divides by the scale.

## Not supported

| Feature | Behaviour |
| --- | --- |
| displacements (`dispinfo`) | detected, preserved as an opaque brush block, reported |
| overlays | they live in entity/`world` data; kept as unknown properties |
| `func_instance` | entity preserved, instance not resolved |
| entity I/O (`connections`) | preserved as an opaque extension |
| embedded/prefab data | preserved opaquely |
| Source 2 formats | out of scope; not implied by Source 1 support |
| subtractive brushes | VMF has no subtractive solid: export warns `vmf.csg-op-unsupported` and writes additive geometry |

## Determinism and identity

Ids are allocated per output document: an authored numeric id is reused when it is
unique, otherwise the next free number is assigned. Face order follows the brush,
brush order follows the entity, so the output is stable for a given input.

## Fixtures

`tests/fixtures/source/cube.vmf` is authored for this repository: a 128-unit cube
(brushes at `-64..64`), one `light`, one `info_player_start`, one material, a
`skyname` and `visgroups`/`viewsettings` blocks. Provenance: written by hand from
the format description above; redistributable with the project.
