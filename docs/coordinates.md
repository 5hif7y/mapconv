# Coordinates, units and transforms

All map data in the IR is expressed in one declared `CoordinateSystem`. Adapters
never apply sign flips or scale factors themselves.

## Canonical frame

The IR's reference frame is:

- right-handed,
- `+Z` up, `+X` east, `+Y` north,
- meters.

A `CoordinateSystem` maps a native frame into it:

```text
canonical_meters = to_canonical * (native_position / units_per_meter)
```

| System | Handedness | Units per meter | `to_canonical` | Source |
| --- | --- | --- | --- | --- |
| `source1` | right | `1 / 0.0254` = 39.3700787 | identity | Source 1 unit = 1 inch |
| `unreal3` | left | `100` | `diag(1, -1, 1)` | UE3 unit = 1 cm, +X forward, +Y right |

`unreal3` mirrors Y when expressed in a right-handed frame, hence the reflection.

## Conversion

`xform.transform_between(from, to)` returns

```text
p_target = linear * p_source * scale,   linear = to.to_canonical^-1 * from.to_canonical
                                        scale  = to.units_per_meter / from.units_per_meter
```

Source -> Unreal therefore scales by `2.54` (1 inch = 2.54 cm) and mirrors Y.
Unreal -> Source scales by `0.3937...` and mirrors Y again.

`mirrored` is `det(linear) < 0`. It drives three behaviours:

1. **Planes.** `apply_plane` transforms three points of the plane and swaps two of
   them when the transform mirrors, so the outward normal keeps pointing at the
   same side of the surface.
2. **Windings.** `apply_winding` transforms the vertices and reverses their order
   when mirrored, so a polygon stays counter-clockwise around its own normal.
3. **Entity angles.** Unreal and Source describe rotation differently. Only the
   yaw/roll sign follows the handedness change deterministically; the conversion
   reports `convert.rotation-approximated` so no one assumes the orientation is
   exact.

## Texture projections

A projection is a world-to-texel covector field. Under a frame change

```text
u_target = (1 / scale) * linear^-T * u_source
offsets and scales are unchanged
```

which keeps the texel value of the same physical point identical. Flipping a
texture axis or rescaling it "to look right" is never implicit.

## Tolerances

`geom.GEOM_EPSILON` (1e-6) is the single geometric tolerance for plane validity,
clipping and point-on-plane tests. `validate` uses a coarser 1.0-unit tolerance
for the convexity check because authored brushes frequently sit exactly on the
limit after a unit conversion. Unit conversion is exact math on `f64`; output is
formatted by `geom.f64_string`, which snaps sub-1e-9 noise and prints at most six
decimals.
