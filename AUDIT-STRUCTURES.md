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
| Interpreted | 3,762,476,746 | 70.62 |
| Uninterpreted | 1,565,324,938 | 29.38 |
| Streamed mips (`*_art.ccpk`) | 3,455,440,074 | decodable, outside these files |

## Priority by uninterpreted bytes

`maps` = how many of the 218 packages contain the class.

| Class | Uninterpreted | Payload | Interpreted | Maps | Source available |
| --- | ---: | ---: | ---: | ---: | --- |
| `SkeletalMesh` | 756,693,429 | 757,058,326 | 0.0 % | 20 | `Engine/Src/UnSkeletalMesh.cpp` |
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
| Current (after AnimSequence) | 3,762,476,746 | 70.62 |


| + `SkeletalMesh` | 4,519,170,175 | 84.82 |
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


## SkeletalMesh implementation notes (measured/source-backed)

`USkeletalMesh::Serialize` after tags, with `LICENSEE == 5` and version 576:

| Step | Field | Size |
| --- | --- | ---: |
| 1 | `Bounds` (FBoxSphereBounds: 2×FVector + FLOAT) | 28 |
| 2 | `Materials` | 4 + 16·N (measured: 2 materials = 32 B) |
| 3 | `Origin`, `RotOrigin` | 12 + 12 |
| 4 | `RefSkeleton` | 4 + 52·N |
| 5 | `SkeletalDepth` | 4 |
| 6 | Vogster byte (`Ver < 592 && Licensee == 5`) | 1 |
| 7 | `LODModels` | FStaticLODModel[] |

`FStaticLODModel::Serialize` (Engine/Src/UnSkeletalMesh.cpp:1350):

1. `Sections` — `TArray<FSkelMeshSection>`; each is 13 B in 576
   (`WORD Material, WORD Chunk, DWORD BaseIndex, DWORD NumTriangles, BYTE Sorting`).
2. `MultiSizeIndexContainer` (`DataType` + index bulk).
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
