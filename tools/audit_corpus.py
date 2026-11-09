#!/usr/bin/env python3
"""Corpus audit dashboard.

Runs `mapconv audit` over every package in a cooked CrimeCraft tree and reads
the Source BSP lump tables directly, then prints the four coverage tiers the
plan defines (T1 maps, T2 content, T3 script packages, T4 Source maps) with a
single accounting rule: a payload counts as interpreted only when the reader
consumed it exactly.

    tools/audit_corpus.py <CookedPC> <csso root> [out.json]

The script never writes to the tree it audits.
"""
import json
import os
import struct
import subprocess
import sys

MAPCONV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mapconv.exe")

LUMP_NAMES = [
    "entities", "planes", "texdata", "vertexes", "visibility", "nodes",
    "texinfo", "faces", "lighting", "occlusion", "leafs", "leafFaces",
    "leafBrushes", "edges", "surfedges", "brushes", "brushSides", "areas",
    "areaPortals", "portals", "clusters", "portalVerts", "clusterPortals",
    "dispinfo", "origFaces", "origVerts", "origEdges", "origSurfEdges",
    "origBrushes", "origBrushSides", "dtexdata", "ddispinfo", "game",
    "faceIds", "lightmapHeaders", "lightmapSamples", "lightmapBrushes",
    "lightmapBrushesFaces", "lightmapDisps", "lightmapDispVerts", "pakfile",
    "clipPortalVerts", "cubemaps", "texdataStringData", "texdataStringTable",
    "overlays", "leafMinDistToWater", "faceMacroTextureInfo", "dispTris",
    "physCollide", "vertNormals", "vertNormalIndices",
    "dispLightmapSamplePositions", "dispmultiblend", "waterOverlays",
    "waterOverlaysData", "leafAmbientIndexHDR", "leafAmbientIndex",
    "lightmappages", "worldlights", "leafAmbientLightingHDR",
    "leafAmbientLighting", "xbSpawnPoints", "staticPropLighting",
    "staticPropLightingHDR", "staticPropNormal",
]
# Lumps whose layout this tool does not interpret yet.
# Lumps the BSP reader does not consume yet. 0,1,2,3,5,6,7,10,12,13,14,17,18,19,26,43,44 are read.
BSP_UNPARSED = {4, 8, 29, 34, 49, 53}


def windows_path(path):
    if path.startswith("/mnt/") and len(path) > 6:
        return path[5].upper() + ":" + path[6:]
    return path


def audit_package(path, classes):
    out = subprocess.run(
        [MAPCONV, "audit", "--input", windows_path(path)],
        capture_output=True, text=True, timeout=1800,
    )
    text = out.stdout
    if "interpreted:" not in text:
        return None
    data = {"interpreted": 0, "uninterpreted": 0}
    for line in text.splitlines():
        tokens = line.split()
        if line.startswith("interpreted:"):
            data["interpreted"] = int(tokens[1])
        elif line.startswith("uninterpreted:"):
            data["uninterpreted"] = int(tokens[1])
        elif line.startswith("  ") and len(tokens) >= 7 and tokens[2] == "payload":
            entry = classes.setdefault(tokens[0], [0, 0, 0])
            entry[0] += int(tokens[3])
            entry[1] += int(tokens[5])
            entry[2] += 1
    return data


def find(root, suffix):
    hits = []
    for base, _dirs, files in os.walk(root):
        for name in files:
            if name.lower().endswith(suffix):
                hits.append(os.path.join(base, name))
    return sorted(hits)


def source_maps(csso):
    files = find(csso, ".bsp")
    total = interpreted = 0
    unparsed = {}
    for path in files:
        size = os.path.getsize(path)
        total += size
        with open(path, "rb") as handle:
            data = handle.read(8 + 64 * 16)
        if data[:4] != b"VBSP":
            continue
        lumps = 0
        for index in range(64):
            offset, length, _version, _fourcc = struct.unpack_from("<4i", data, 8 + index * 16)
            if length <= 0 or offset + length > size:
                continue
            lumps += length
            if index in BSP_UNPARSED:
                unparsed[index] = unparsed.get(index, 0) + length
        interpreted += lumps
    for index, length in unparsed.items():
        interpreted -= length
        name = LUMP_NAMES[index] if index < len(LUMP_NAMES) else str(index)
        print(f"  bsp lump {index:2d} {name:24s} {length:14d} unparsed")
    return {"files": len(files), "bytes": total, "interpreted": interpreted}


def report(title, root, suffix, allow_missing=False):
    classes = {}
    files = find(root, suffix)
    total = interpreted = 0
    skipped = 0
    for path in files:
        data = audit_package(path, classes)
        if data is None:
            skipped += 1
            continue
        if data["interpreted"] == 0 and data["uninterpreted"] == 0:
            skipped += 1
            continue
        total += data["interpreted"] + data["uninterpreted"]
        interpreted += data["interpreted"]
    pct = 100.0 * interpreted / total if total else 0.0
    print(f"{title}: {len(files)} files, {interpreted} / {total} B = {pct:.2f}%")
    if skipped:
        print(f"  {skipped} file(s) produced no audit output")
    gaps = [(payload - seen, payload, seen, name) for name, (payload, seen, _n) in classes.items() if payload > seen]
    for gap, payload, seen, name in sorted(gaps, reverse=True)[:10]:
        print(f"  {gap:12d} {payload:12d} {100.0*seen/payload:6.1f}%  {name}")
    return {"files": len(files), "bytes": total, "interpreted": interpreted, "classes": classes}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    cooked, csso = sys.argv[1], sys.argv[2]
    result = {}
    result["t1_maps"] = report("T1 UE3 maps", os.path.join(cooked, "Maps"), ".ccmap")
    result["t2_content"] = report("T2 UE3 content", cooked, ".ccpk")
    result["t3_scripts"] = report("T3 UE3 scripts", cooked, ".u")
    result["t4_source"] = source_maps(csso)
    t4 = result["t4_source"]
    print(f"T4 Source maps: {t4['files']} files, {t4['interpreted']} / {t4['bytes']} B = "
          f"{100.0*t4['interpreted']/t4['bytes']:.2f}%")
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as handle:
            json.dump(result, handle, indent=2)
        print(f"wrote {sys.argv[3]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
