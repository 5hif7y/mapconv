# Source 1 BSP adapter (import only)

The `bsp` package reads compiled Source 1 maps (`VBSP`, version 20, Orange Box
era) and converts them into the canonical IR. There is no exporter: `mapconv` is
not a BSP compiler. To get a playable Source map, convert to VMF and compile it
with VBSP, or convert to T3D and let UnrealEd cook it.

## What the file gives us

| Lump | Used for |
| --- | --- |
| 0 entities | the entity list, parsed with the shared `kv` tree |
| 1 planes | brush side and face planes |
| 2 texdata + 43/44 string table | material names |
| 3 vertexes, 12 edges, 13 surfedges | face polygons |
| 5 nodes, 10 leaves, 16/17 leaf faces/brushes | the BSP tree, brush ownership |
| 6 texinfo | texture projection and material index |
| 7 faces | face planes, texinfo, displacements |
| 14 models | world model and brush-entity models |
| 18 brushes, 19 brush sides | authored brushes of brush entities |
| 26 dispinfo | displacement count, reported |

Record sizes matter and are not all obvious: `dnode_t` and `dleaf_t` occupy 32
bytes on disk (30 bytes of fields plus 2 bytes of padding), which the lump sizes
confirm (`nodes = length / 32`, `leafs = length / 32`). Leaf brush and leaf face
ranges were verified against the `leafbrushes`/`leaffaces` lump lengths of
`de_dust2`.

## World geometry is reconstructed, not authored

A compiled BSP no longer stores the mapper's world brushes: the compiler cut the
world along the BSP tree. Reconstruction follows the method of ericw-tools'
`bsputil --decompile`:

1. every non-empty leaf is the region behind all the planes on the path to it,
   bounded by the model's bounds — that region becomes one convex brush;
2. redundant planes are removed (duplicates, and planes that do not bound the
   region);
3. each side takes the material and texture projection of the largest face of its
   node that looks the same way and lies inside the brush;
4. a side no face touches is hidden and takes the material of the most opposite
   side, or the material of the leaf's contents (`TOOLS/TOOLSSKYBOX`,
   `TOOLS/TOOLSWATER`, `TOOLS/TOOLSNODRAW`).

Consequences, also stated in `docs/ir.md`: the brushes are **reconstructed**
(`winding_source = Derived`), not the brushes the mapper used. Several original
brushes may come back as one, and one as several.

Brush entities are different: their brushes are still in the brush lumps, so they
are read as authored (planes, sides, texinfo) and attached to the entity through
its model's leaves.

## Attribution and licensing

The reconstruction method is ericw-tools' (`bsputil --decompile`), which is
GPL-2.0-or-later. The BSP struct layouts come from Valve's public Source SDK
headers (`public/bspfile.h`). This repository's licence is still TBD: if `mapconv`
is meant to be distributed under a non-GPL licence, this adapter has to be
re-implemented from the format description or the project licence has to become
GPL-compatible. That decision is open.

## Fidelity

| Feature | Behaviour |
| --- | --- |
| world brushes | reconstructed from the tree, reported as one brush per solid leaf |
| brush entity brushes | read from the brush lumps |
| materials | names only (`maps/de_dust2/...`); no VMT/VTF is read |
| texture projection | exact: texinfo stores texels-per-world-unit vectors |
| displacements | base surface exported, displacement geometry reported (`bsp.displacements`) |
| overlays, decals, sprites | entity/asset data preserved as properties where present, not converted |
| clip/origin/nodraw volumes | kept as brushes with their contents material |
| lightmaps, HDR lighting, cubemaps, visibility | not read (they are baked data) |
| embedded pakfile (textures) | not extracted |
| entity brush origins | brush planes are used as stored (world space) |

Measured on the bundled examples (2026-11, this machine, one thread):

| Map | Brushes | Faces | Time | Notes |
| --- | --- | --- | --- | --- |
| `cs_assault.bsp` | 1737 | 10 535 | 0.5 s | 890 entities |
| `de_dust2.bsp` | 1992 | 12 068 | 0.7 s | 69 displacements, 269 sides with mixed textures resolved by largest face |

Both maps are larger in `mapconv` terms than the source leaves suggest because a
few leaves produce fewer than four usable planes; those are counted in
`bsp.leafs-skipped`.

## Pipeline

```text
CS:S .bsp -> mapconv -> .vmf  -> Hammer/VBSP -> playable Source map
                      \-> .t3d -> UnrealEd import -> cook -> CrimeCraft .ccmap
```

The `.ccmap` half of that pipeline is not implemented yet; see `README.md`.
