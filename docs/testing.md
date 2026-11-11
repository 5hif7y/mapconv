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
| UE3 levels | `ue3/level_test.odin` — a synthetic `ULevel`: the `Actors` owner and references, URL strings/port/validity, model and component references, and actor class resolution |
| UE3 actors | `ue3/actor_test.odin` — a synthetic `RF_HasStack` actor: the state-frame prelude, `NetIndex` and tagged `Location`/`Rotation`/`DrawScale` read back as an actor transform, the component template-owner prefix, and a light with `Brightness`/`LightColor` |
| UE3 textures | `ue3/texture_test.odin` — a synthetic `Texture2D` with one inline DXT1 4x4 mip: properties, bulk records, DDS header and payload; a streamed mip is reported and produces no DDS |
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

## In-engine validation (not yet satisfactory)

Automated runs under WSL start the game and capture the desktop with PowerShell,
but the results so far are **not conclusive**:

- some captures show the loading screen only (large maps take minutes);
- one run reached the map (HUD, warmup) but the window later disappeared before
  the next capture;
- textures/geometry changes could not be judged from those frames, so in-engine
  verification is considered **pending**, not passing.

### What the next harness must do

1. Enter **spectator/noclip** so the camera can be placed deterministically:
   ```
   csso_win64.exe -game csso -novid -windowed -w 1280 -h 720 \
     +sv_cheats 1 +map arena01 +noclip
   ```
   then in the console (or via `+` commands):
   ```
   cl_showpos 1          // prints "pos x y z; ang ..." every frame
   spec_mode 1           // free look once dead/spectating
   setpos -1200 800 320  // chosen viewpoint
   ```
2. Add `-condebug` so `csso/console.log` records the `cl_showpos` lines; parse the
   last `pos` line to know exactly where the camera ended up.
3. Take the screenshot only after the log shows the map's `Level` loaded (search
   for the map name and the absence of `Loading` lines), not on a fixed sleep.
4. Store the chosen `(pos, ang)` pairs per map in a small JSON fixture so a run is
   reproducible and diffs between runs are meaningful.

Until that harness exists, treat in-engine screenshots as exploratory evidence
only; the byte/asset audits in `AUDIT.md` are the authoritative measurements.

## Coverage as a test: the measurement gate

The unit tests fix what the readers *do*; they cannot see what the corpus *is*, because
the corpus is 32 GB and does not enter the repository. `mapconv audit` closes that gap by
turning coverage into a number a command can compare.

```bash
# Measure a tree and keep the document.
mapconv audit --corpus <corpus> --json --output baseline.json

# Fail if anything in it regressed since that measurement.
mapconv audit --corpus <corpus> --json --diff tests/baseline-corpus.json
```

`tests/baseline-corpus.json` is the measurement of the 629 files this toolkit reads
(218 `.ccmap`, 320 `.ccpk`, 9 `.u`, 82 `.bsp`): 17,071,078,138 bytes, 17,071,078,136 of
them attributed, **2 uninterpreted**, 1,165,142 objects, 3,853 lumps, 1,040,883 lightmap
blocks, 126 lighting lumps tiled, 169,493,560 luxels, 4,234 PhysX convex elements and
8,989 material shader maps. The run takes about a minute and a half.

What the diff refuses, and why each rule exists:

| Refused | Because |
| --- | --- |
| fewer interpreted bytes in a file | the reader stopped explaining bytes it used to explain |
| more uninterpreted bytes in a file | the residual grew, which is the only number that must never grow |
| a counter that fell | the same bytes can be consumed while walking fewer of the structures inside them (luxels, lightmap blocks, lumps, PhysX elements, shader maps) |
| a file measured before and absent now | a corpus that stopped being readable must not read as a smaller corpus |

A file whose size changed is **not** compared: that is a different measurement, not a
regression. Files are keyed by name *and* size, because the corpus holds two maps called
`de_nuke.bsp`. A document of an unknown schema is refused rather than compared, since
numbers whose meaning changed are not numbers that can be compared.
