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
| VMF | `vmf/vmf_test.odin` — tokenizer escapes/comments, plane parsing, texture axes, fixture import (6 faces, materials, entities), unknown-key namespacing, export/import round trip, malformed input, subtractive-CSG warning |
| T3D | `t3d/t3d_test.odin` — tokenizer quoting, vector/rotation parsing, nesting, fixture import (6 polygons, flags, rotation), export/import round trip, malformed blocks, missing map, polygon-list fragment |
| Conversion | `convert/convert_test.odin` — format detection, VMF→T3D (units, mapping, transform note), T3D→VMF (brush actors collapse into the world), geometry round trip, subtractive CSG warning, unmapped class warning, unsupported target, validation |

## Fixtures

| Fixture | Contents | Provenance |
| --- | --- | --- |
| `tests/fixtures/source/cube.vmf` | 128-unit cube, `light`, `info_player_start`, one material, `skyname`, `visgroups`, `viewsettings` | authored for this repository from `docs/formats/vmf.md` |
| `tests/fixtures/unreal/cube.t3d` | brush actor with six polygons (±128 units), `PointLight`, one material, `Flags=1` | authored for this repository from the UE3 exporter grammar in `docs/formats/t3d.md` |

Both are redistributable with the project. Larger, game-specific fixtures should
be added with provenance and redistribution permission recorded here.

## Not covered yet

- byte-for-byte round trips (serializers normalise order, ids and formatting by
  design; tests compare semantics instead),
- real engine-produced maps (only hand-authored fixtures),
- CSG evaluation and convex decomposition,
- resource/asset resolution,
- CLI end-to-end tests (the CLI is exercised manually; see the examples in
  `README.md`).
