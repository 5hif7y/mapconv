# Testing

Tests are Odin `@(test)` procedures inside each package (`*_test.odin`). They run
from the module root, because fixture paths are module-relative.

```sh
make test            # every package with tests, one line each
make test-verbose    # full `odin test` output per package
odin test convert    # a single package
odin test convert -define:ODIN_TEST_NAMES=convert.test_vmf_to_t3d
```

`ir`, `diag` and `profile` currently have no tests of their own; their behaviour
is covered through the adapter and conversion tests. `odin test` on a package
without tests fails to link (`__$all_tests_array`), which is why `make test` skips
those packages.

The test runner reports allocations as leaks. `mapconv` is a short-lived CLI and
the IR intentionally does not free itself; leak warnings are informational, not
failures.

## What is covered

| Area | Tests |
| --- | --- |
| Plane and winding math | `geom/geom_test.odin` — plane from map points, plane/point round trip, degenerate input, cube face clipping, winding orientation, half-space clipping, matrix inverse, numeric formatting |
| Coordinate systems | `xform/xform_test.odin` — inch/centimetre scale, Y mirror, round-trip identity, outward normals under mirroring, winding orientation, texture-projection invariance |
| Rotation | `xform/xform_test.odin` — known Source/Unreal rotator values, degree/unit round trip, and a check that both engines' rotation matrices agree after the Y mirror |
| VMF | `vmf/vmf_test.odin` — tokenizer escapes/comments, plane parsing, texture axes, fixture import (6 faces, materials, entities), unknown-key namespacing, export/import round trip, malformed input, subtractive-CSG warning |
| T3D | `t3d/t3d_test.odin` — tokenizer quoting, vector/rotation parsing, nesting, fixture import (6 polygons, flags, rotation), export/import round trip, malformed blocks, missing map, polygon-list fragment |
| BSP | `bsp/bsp_test.odin` — a synthetic Source BSP 20 with an entity brush: lump parsing, texture names, brush sides, leaf/brush ownership, model 1, and rejection of a file without the VBSP signature |
| UE3 packages | `ue3/ue3_test.odin` — a synthetic 576/5 package assembled byte by byte: summary fields and offsets, name entries with 64-bit flags, UTF-16 name entries, import/export records, `FPackageIndex` resolution, `FName` number suffix, table-bound checks, and rejection of a bad tag or a truncated file |
| UE3 object payloads | `ue3/object_test.odin` — object prelude with a `BoolProperty` tag and the `"None"` terminator, a `UPolys` with one quad polygon, bounds-limited reads, the size-mismatch and truncation diagnostics, and an end-to-end import of a synthetic cube (six world-space quads, local `Base`) into one IR brush with six faces |
| UE3 models | `ue3/model_test.odin` — a synthetic `UModel` with one quad node, one surface and four verts: bulk headers, the `TTransArray` owner before the surface count, polygon resolution through `Verts`/`Points`, the size-mismatch warning and a rejected bulk element size |
| Conversion | `convert/convert_test.odin` — format detection, VMF→T3D (units, mapping, transform note), T3D→VMF (brush actors collapse into the world), geometry round trip, subtractive CSG warning, unmapped class/property reporting, light colour and brightness in both directions, rotation in both directions, `targetname`↔`Tag`, unsupported target, validation |

## Fixtures

| Fixture | Contents | Provenance |
| --- | --- | --- |
| `tests/fixtures/source/cube.vmf` | 128-unit cube, `light`, `info_player_start`, one material, `skyname`, `visgroups`, `viewsettings` | authored for this repository from `docs/formats/vmf.md` |
| `tests/fixtures/unreal/cube.t3d` | brush actor with six polygons (±128 units), `PointLight`, one material, `Flags=1` | authored for this repository from the UE3 exporter grammar in `docs/formats/t3d.md` |
| `examples/CSSO maps/**/*.bsp` | 76 real CS:S maps | used manually for BSP smoke tests (`mapconv inspect`/`convert`); not part of the test suite and not redistributed with the repository |
| `examples/CrimeCraft maps/**/*.ccmap` | 218 real UE3 cooked packages | used manually for package smoke tests (`mapconv inspect`/`validate`); all 218 were checked while documenting the layout in `docs/formats/ue3-package.md`; not part of the test suite |

Both are redistributable with the project. Larger, game-specific fixtures should
be added with provenance and redistribution permission recorded here.

## Not covered yet

- byte-for-byte round trips (serializers normalise order, ids and formatting by
  design; tests compare semantics instead),
- real engine-produced maps (only hand-authored fixtures),
- UE3 object payloads, properties and compressed chunks (tables only),
- CSG evaluation and convex decomposition,
- resource/asset resolution,
- CLI end-to-end tests (the CLI is exercised manually; see the examples in
  `README.md`).
