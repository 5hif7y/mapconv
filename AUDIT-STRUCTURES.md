# Audit of uninterpreted structures (research plan)

Status: 2025-11-09. Corpus: 218 `.ccmap` maps, 5,327,801,684 bytes.

## Method

A structure counts as *interpreted* only when the reader consumes the export
payload exactly (`cursor == serial_offset + serial_size`). Anything else stays
uninterpreted; no layout is committed without that check. Measurements come from
`mapconv audit` over the whole corpus, aggregated per class.

Current state:

| Metric | Bytes | % |
| --- | ---: | ---: |
| Interpreted | 4,519,170,175 | 84.82 |
| Uninterpreted | 808,631,509 | 15.18 |
| Streamed mips (`*_art.ccpk`) | 3,455,440,074 | decodable, outside these files |

## Priority by uninterpreted bytes

`maps` = how many of the 218 packages contain the class.

| Class | Uninterpreted | Payload | Interpreted | Maps | Source available |
| --- | ---: | ---: | ---: | ---: | --- |
| `SkeletalMesh` | 0 | 757,058,326 | 100.0 % | 20 | done (`ue3/skeletal_mesh.odin`) |
| `StaticMeshComponent` | 709,401,800 | 723,039,376 | 1.9 % | 142 | **no source** |
| `AnimSequence` | 0 | 213,339,252 | 100.0 % | 24 | done (`ue3/anim.odin`) |
| `SoundNodeWave` | 0 | 191,429,414 | 100.0 % | 142 | done (`ue3/sound.odin`) |
| `DecalComponent` | 12,843,596 | 13,456,116 | 4.6 % | 31 | `Engine/Src/DecalComponent.cpp` |
| `SpeedTreeComponent` | 11,102,672 | 11,294,824 | 1.7 % | 18 | licensed, stripped |
| `BrushComponent` | 5,276,289 | 9,166,529 | 42.4 % | 129 | `Engine/Src/...` partial |
| `Texture2D` (tail) | 3,579,777 | 266,562,629 | 98.7 % | 128 | best effort |
| `Level` | 3,164,920 | 3,167,536 | 0.1 % | — | `Engine/Src/UnLevel.cpp` |
| `Material` (tail) | 3,084,077 | 4,693,284 | 34.3 % | — | partial |
| `SpeedTree` | 1,462,599 | 1,490,923 | 1.9 % | — | licensed |
| `ModelComponent` | 445,700 | 465,696 | 4.3 % | — | partial |

The four largest blocks hold 1,856 MB, i.e. 95 % of everything that is still
uninterpreted.

## Projection

| Step | Cumulative | % |
| --- | ---: | ---: |
| Current (after SkeletalMesh) | 4,519,170,175 | 84.82 |



| + `Level`, `Decal`, `Brush`, tails | ~4,545,000,000 | ~85.3 |

Reaching 90 % requires 4,795,021,516 bytes: another ~250 MB, which is ~35 % of
`StaticMeshComponent`. So 90 % is reachable from *sourced* classes alone, and
would become comfortable with a partial `StaticMeshComponent` reader.

## Investigation cards

### 1. `SoundNodeWave` — 190 MB, 0.7 %, source `UnAudioNodes.cpp`

Lowest risk: source exists and the class is small per object. Read
`USoundNodeWave::Serialize` (bulk `RawData`, `CompressedData`, `PCMData`,
`DecompressedData`, platform format) and consume the payload exactly. Payload is
audio bytes; interpretation means skipping them with the right headers, not
decoding them.

### 2. `AnimSequence` — 200 MB, 6.3 %, source `UnSkeletalAnim.cpp`

Read `UAnimSequence::Serialize`: `Sequence`, `AnimTrack`/`CompressedTrack`
arrays, key counts, `SeqName`. 24 maps, 200 MB. Needs the bone count only if the
track format depends on it; prefer the compact cooked path.

### 3. `SkeletalMesh` — 757 MB, 0.0 %, source `UnSkeletalMesh.cpp`

20 objects, ~38 MB average: a handful of very large meshes. Read `Serialize`
(materials, bone hierarchy, `LODModels` / `SkeletalMeshLODInfo`, skinned vertex
buffers, `SkinnedVertexInfluences`, `ReferenceSkeleton`). High impact, medium
risk; validate per-object because one mis-sized buffer shifts the next.

### 4. `StaticMeshComponent` — 709 MB, 1.9 %, **no source**

Evidence gathered so far (arena01, 6 largest components):

- common prefix `ref, 0, 0, 1, N` with `N` in 6..11;
- `body - 20` is a multiple of 4 in all six (probability 1/4096 by chance);
- payload is raw (no zlib, no LZO header; entropy 5.69 bit/B);
- `_151`/`_152` share payload bytes from offset 20 with different `N` and sizes;
- first i32 does **not** resolve to a `StaticMesh` package index (resolves to
  `AmbientSound` exports);
- no `count * stride` (strides 4..48) consumes the body, neither forward nor as
  a trailing array.

Falsified: flat `TArray<FColor>`, inline bulk header, zlib/LZO compression,
`N` as stride or count, mesh package index.

Next: derive the component layout from `UnSkeletalComponent.cpp` (same family,
same `LODData` idea) or from a UE3 build that ships `StaticMesh.cpp`. Do not
write a reader before a layout consumes the export exactly.



### Measured LOD0 chain (export 82, `CH_MNPCguard01_lobby`)

| Step | Offset | Value |
| --- | ---: | --- |
| tags end | 345 | — |
| `Bounds` | 345 | 7 floats |
| `Materials` | 373 | 2 × 4 B |
| `Origin` / `RotOrigin` | 385 | (0, 0, −43) + 12 B |
| `RefSkeleton` | 409 | 52 × 52 B |
| `SkeletalDepth` | 3117 | 12 |
| Vogster byte | 3121 | 0 |
| `LODModels` | 3122 | 2 |
| `Sections` | 3126 | 2 × 10 B: (0,0,0,4990), (1,1,14970,3075) |
| index container | 3150 | `DataTypeSize=2`, `NumIndices=24195`, 24195 × WORD |
| shadow indices | 51548 | 24195 × WORD |
| `ActiveBoneIndices` | 99942 | 43 × WORD |
| shadow double-sided | 100032 | 8065 × BYTE |
| `Chunks` | 108101 | 2 chunks |
| chunk 0 | 108105 | base 0, rigid 4136 × **61 B**, soft 2587 × **68 B**, bones 42 × WORD, NumRigid 4136, NumSoft 2587, MaxBone 4 |
| chunk 1 | 536433 | base 6723, rigid 4779 × 61 B, soft 0, bones 1, NumRigid 4779, NumSoft 0, MaxBone 1 |
| `Size` / `NumVertices` | 827978 | 0 / 11502 (rigid+soft sums match) |
| `LegacyEdges` | 827986 | 12514 × **16 B** |
| `RequiredBones` | 1028218 | 52 × BYTE |
| `RawPointIndices` | 1028270 | flags 0, count 11502, size 23004, offset 10159129; data inline |
| `VertexBufferGPUSkin` | 1051290 | bUseFullPrecisionUVs=0, **stride 48**, NumVertices 11502, 552,096 B of data |

The chunk vertex arrays confirm the 61/68 byte vertex sizes (the trailing
NumRigid/NumSoft/MaxBone triples line up exactly). After the LOD0 vertex data
the next bytes are not a clean LOD1 header yet, so the LOD0 tail
(`ColorVertexBuffer` when the tags say `bHasVertexColors`, `VertexInfluences`,
or a bulk with a different header) still needs one more measurement before the
reader can be written end to end.

## SkeletalMesh implementation notes (measured/source-backed)

`USkeletalMesh::Serialize` after tags, with `LICENSEE == 5` and version 576:

| Step | Field | Size |
| --- | --- | ---: |
| 1 | `Bounds` (FBoxSphereBounds: 2×FVector + FLOAT) | 28 |
| 2 | `Materials` | 4 + 4·N (2 materials = 8 B; verified at +377..+385) |
| 3 | `Origin`, `RotOrigin` | 12 + 12 |
| 4 | `RefSkeleton` | 4 + 52·N |
| 5 | `SkeletalDepth` | 4 |
| 6 | Vogster byte (`Ver < 592 && Licensee == 5`) | 1 |
| 7 | `LODModels` | FStaticLODModel[] |

`FStaticLODModel::Serialize` (Engine/Src/UnSkeletalMesh.cpp:1350):

1. `Sections` — `TArray<FSkelMeshSection>`; each is **10 B** in 576:
   `WORD Material, WORD Chunk, DWORD BaseIndex, WORD NumTriangles` (no sorting
   byte below `VER_SKELETAL_MESH_SORTING_OPTIONS`). Verified on export 82:
   sections at +3126 (count 2), +3130 `(0,0,0,4990)`, +3140 `(1,1,14970,3075)`.
2. `MultiSizeIndexContainer`: for 576 the header is `u32 DataTypeSize (=2)`
   followed by `u32 NumIndices` and `NumIndices × WORD` (measured: 2, 24195 at
   +3150), then the index words.
3. `ActiveBoneIndices` (`TArray<WORD>`).
4. `Chunks` (`TArray<FSkelMeshChunk>`).
5. `Size`, `NumVertices`.
6. `RequiredBones` (`TArray<BYTE>`).
7. `RawPointIndices` (FBulkData).
8. `NumTexCoords` then `VertexBufferGPUSkin` (stride depends on `NumTexCoords`;
   `FRigidSkinVertex` 61 B / `FSoftSkinVertex` 68 B with 4 UVs per the source
   comments).
9. `ColorVertexBuffer` only when the tags say `bHasVertexColors`.
10. `VertexInfluences` (≥ `VER_ADDED_EXTRA_SKELMESH_VERTEX_INFLUENCES`).

After `LODModels`: `NameIndexMap`, `PerPolyBoneKDOPs`, `BoneBreakNames` and
`BoneBreakOptions` (gated). The Vogster byte and the vertex stride are the two
places where a wrong guess shifts everything, so the reader must consume the
export exactly and refuse otherwise.

Measured example: `CH_MNPCguard01_lobby` (export 82 of
`Characters_Male_combocloth.ccpk` at 9130843) — tags end +345, `Bounds` +345,
`Materials` count +373 (=2), `RefSkeleton` count +409 (=52, 52×52 B), last
`BoneColor` = FFFFFFFF at +3117, `SkeletalDepth` +3117 (=12), Vogster byte
+3121, `LODModels` count +3122 (=2), sections +3126.

### 5. `Level` — 3.2 MB, 0.1 %, source `UnLevel.cpp`

Our reader consumes only 12 B of a 1.5 MB `Level` in arena01. The class is not a
priority by bytes but is structurally central; fixing it may explain the
`StaticMeshComponent` tail as well.

### 6. `Texture2D` tail — 3.6 MB, 98.7 %

Remaining bytes are per-object source art or unsupported formats; audit lists
them per object. Low priority.

### 7. `DecalComponent`, `BrushComponent`, `Material`, `ModelComponent`

Small blocks (MB range). Fix after the four large ones; `DecalComponent.cpp`
source is available.

## Protocol for each reader

1. Read the source, write the struct layout as comments with version gates.
2. Implement `read_*` returning a diagnostic on truncation or version mismatch.
3. Require exact end-of-export; otherwise report and do **not** count as
   interpreted.
4. Add a fixture-based test (extracted payload slice + expected field values).
5. Re-run `mapconv audit` on arena01, then the 218-map corpus; interpretation
   must rise and never regress.
6. Only after the corpus passes 90 % start in-engine validation
   (`tools/capture_map.sh`).

## Reproduce

```sh
grep -c . /tmp/maps.txt                       # 218
./mapconv.exe audit --input <map>.ccmap
awk '/^  [A-Za-z]/{name=$1; pay=$4; intr=$6; if (pay+0>0){p[name]+=pay; i[name]+=intr}}
     END{for (n in p){u=p[n]-i[n]; if(u>100000) printf "%d %d %.1f%% %s\n", u, p[n], 100*i[n]/p[n], n}}' \
     /tmp/audit_all.txt | sort -rn      # per-class totals of the corpus
```
