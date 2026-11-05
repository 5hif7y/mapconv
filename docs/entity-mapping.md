# Entity mapping

Converting a map is not only converting geometry. Entities carry class names,
typed properties and conventions that differ between engines, and a similar name
never implies identical behaviour. Entity mapping is therefore a separate,
data-driven stage of `convert`, not something each adapter does.

## Policy

- Mapping runs **only across formats**. A same-format pass (VMF → VMF, T3D → T3D)
  never rewrites properties, so round trips stay faithful.
- Rules live in `profile` as tables (`SOURCE_TO_UNREAL_PROPERTIES`,
  `UNREAL_TO_SOURCE_PROPERTIES`). Adding a game or engine variant means adding
  data, not editing the pipeline.
- A property with a rule is **consumed**: it is converted, dropped or reported,
  and never copied verbatim into the target unless the rule says so.
- A property without a rule is reported (`convert.property-unmapped`) and dropped.
  Writing foreign property names into a T3D or VMF file would produce a file the
  editor rejects or silently misreads.
- Keys that the adapters already consume into typed IR fields (`id`, `classname`,
  `origin`, `location`, `prepivot`, `csgoper`) and adapter bookkeeping
  (`source_*`, `mapconv.*`) are not reported.

## Class mapping

`DEFAULT_SOURCE_TO_UNREAL` and `DEFAULT_UNREAL_TO_SOURCE` rename classes when a
plausible counterpart exists:

| Source 1 | Unreal Engine 3 | Note |
| --- | --- | --- |
| `info_player_start` | `PlayerStart` | spawn point |
| `info_player_terrorist` / `info_player_counterterrorist` | `PlayerStart` | team spawns collapse |
| `light` | `PointLight` | colour and brightness mapped, falloff not |
| `light_spot` | `SpotLight` | cone angles not converted |
| `light_environment` | `SkyLight` | direction/colour mapping not implemented |
| `prop_static` | `StaticMeshActor` | asset reference not resolved |
| `prop_dynamic` / `prop_physics` | `KActor` | physics behaviour not converted |
| `func_detail` / `func_brush` / `func_wall` | `Brush` | geometry only; CSG semantics differ |
| `func_door` | `InterpActor` | movement behaviour not converted |
| `trigger_multiple` | `Trigger` | volume only |

A class mapped to an empty target has no actor equivalent: if it owns brushes they
move to the world (`convert.entity-collapsed`), otherwise it is kept and reported
(`convert.class-without-actor`). An unmapped class keeps its name and raises
`convert.unmapped-class`.

## Property mapping

### Source 1 → Unreal Engine 3

| Source key | Behaviour |
| --- | --- |
| `_light` | `"R G B brightness"` → `LightColor=(R=..,G=..,B=..,A=255)` and `Brightness` (see below) |
| `angles` | Source pitch/yaw/roll in degrees → Unreal `Rotation` (see below) |
| `targetname` | → `Tag` (naming only; no I/O relationship is created) |
| `model` | asset reference: reported, not resolved, dropped |
| `_lightHDR`, `_lightscale` | dropped, reported |
| `_fifty_percent_distance`, `_zero_percent_distance`, `_quadratic_attn`, `_linear_attn`, `_constant_attn` | dropped, reported (baked light data, not authored) |
| `style`, `spawnflags`, `rendermode`, `renderamt`, `rendercolor`, `renderfx`, `disablereceiveshadows` | dropped, reported |

### Unreal Engine 3 → Source 1

| Unreal key | Behaviour |
| --- | --- |
| `LightColor` + `Brightness` | → `_light "R G B brightness"` (see below) |
| `Rotation` | → `angles` (see below) |
| `Tag` | → `targetname` |
| `StaticMesh` | asset reference: reported, not resolved, dropped |
| `DrawScale`, `DrawScale3D` | dropped, reported |
| `PrePivot` | dropped; the importer already folds it into the actor origin |
| `bHiddenGame` | dropped, reported |

## Lights

Source stores colour and brightness in one string:

```text
_light "R G B brightness"        R,G,B in 0..255, brightness in 0..2000
```

Unreal 3's `ULightComponent` has `LightColor` (a `Color` struct) and `Brightness`
(a float, default 1.0, UI range 0..20 — see `Engine/Classes/LightComponent.uc`).

```text
Unreal.Brightness = Source.brightness / 200      (200 = a default Source light)
Source.brightness = Unreal.Brightness * 200
LightColor        = (R, G, B, A=255)             exact, no gamma or colour-space change
```

Colour is exact; brightness is normalised, and the conversion emits
`convert.light-brightness-scaled` with both values so the scale is visible. This is
a deliberate, documented approximation, not a claim of photometric equivalence.

Falloff (`_fifty_percent_distance`, attenuation constants), light styles, HDR
values and spot cone angles are not converted: Unreal expresses falloff with
`Radius`/`FalloffExponent`, which do not correspond one-to-one to Source's baked
parameters.

## Rotation

The conversion is derived from the two engines' rotation matrices, not guessed.
Source 1 (`AngleVectors` in the Source SDK) builds:

```text
X = ( cp*cy,  cp*sy, -sp )
Y = ( -sr*sp*cy + cr*sy,  -sr*sp*sy - cr*cy,  -sr*cp )
Z = ( cr*sp*cy + sr*sy,   cr*sp*sy - sr*cy,    cr*cp )
```

Unreal 3 (`FRotationTranslationMatrix` in `Core/Inc/UnMath.h`) builds:

```text
X = ( CP*CY,  CP*SY,  SP )
Y = ( SR*SP*CY - CR*SY,  SR*SP*SY + CR*CY,  -SR*CP )
Z = ( -(CR*SP*CY + SR*SY),  CY*SR - CR*SP*SY,  CR*CP )
```

The frame change between them is the Y mirror `M = diag(1, -1, 1)`. Applying `M` to
the Source axes and solving for the Unreal rotator gives:

```text
Pitch_unreal = -Pitch_source
Yaw_unreal   = -Yaw_source
Roll_unreal  = +Roll_source
```

Roll keeps its sign because both engines roll the up vector towards the right;
the handedness flip and the axis flip cancel. `xform/xform_test.odin` verifies the
mapping by rebuilding both engines' axes for several angle triples and comparing
them after the mirror.

Units: Source uses degrees, Unreal rotators use 65536 units per turn
(`FRotator::Euler`/`MakeFromEuler` in `UnMath.cpp`):

```text
units = round(degrees * 65536 / 360)      wrapped into [-32768, 32767]
```

One unit is 0.0055 degrees, so a round trip is accurate to about 0.01 degrees.

## Not mapped yet

- Entity I/O: `target`/`targetname` relationships, `connections` blocks,
  Unreal `Event`/`Tag` graphs.
- `spawnflags` semantics, team spawns beyond `PlayerStart`.
- Game-specific entity sets (Counter-Strike, Half-Life 2, UDK samples).
- Material and asset resolution (paths are preserved, assets are not converted).
- Any world-level settings (`skyname`, lightmaps, fog).

Adding a rule is mechanical: append a `Property_Rule` to the profile table, give it
an operation and a note, and cover it with a conversion test. Class-scoped rules
(same key, different meaning per class) are the next step; the current table is
keyed by property name because the supported keys are unambiguous across the
default profiles.
