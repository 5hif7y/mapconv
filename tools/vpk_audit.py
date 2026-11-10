#!/usr/bin/env python3
"""Measure VPK archives without extracting them.

The tree of a version 2 directory file is a list of entries written as

    first entry : ext NUL path NUL name NUL record
    next entry  : Z leading NULs, then
                    Z = 0  same extension and path   -> name
                    Z = 1  same extension, new path  -> path, name
                    Z = 2  new extension and path    -> ext, path, name
                    Z = 3  end of tree
    record      : crc32 (4) preload (2) archive (2) offset (4) length (4) 0xFFFF (2)

The rule was derived from the corpus: with it the tree of every directory file is
consumed exactly, the terminator included. Names are never empty, so a leading NUL
cannot be mistaken for the start of a name.

Usage: tools/vpk_audit.py <game root> [more roots...]
"""
import os
import struct
import sys

HEADER = 28
RECORD = 18
TERMINATOR = 0xFFFF


def read_cstring(data, pos):
    end = data.index(b"\0", pos)
    return data[pos:end].decode("latin1"), end + 1


def parse_tree(path):
    """Returns (entries, errors). An entry is (ext, path, name, crc, preload,
    archive, offset, length)."""
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < HEADER:
        return [], [f"{path}: shorter than a VPK header"]
    sig, version, tree_size = struct.unpack_from("<III", data, 0)
    if sig != 0x55AA1234 or version != 2:
        return [], [f"{path}: not a version 2 VPK (sig 0x{sig:08X}, version {version})"]
    pos, end = HEADER, HEADER + tree_size
    if end > len(data):
        return [], [f"{path}: tree lies outside the file"]
    entries, errors = [], []
    ext = path_field = ""
    first = True
    while pos < end:
        if first:
            ext, pos = read_cstring(data, pos)
            path_field, pos = read_cstring(data, pos)
            first = False
        else:
            zeros = 0
            while pos + zeros < end and data[pos + zeros] == 0 and zeros < 3:
                zeros += 1
            if zeros >= 3:
                pos += zeros
                break
            pos += zeros
            if zeros == 2:
                ext, pos = read_cstring(data, pos)
                path_field, pos = read_cstring(data, pos)
            elif zeros == 1:
                path_field, pos = read_cstring(data, pos)
        name, pos = read_cstring(data, pos)
        if pos + RECORD > end:
            errors.append(f"{path}: entry header past the tree")
            return entries, errors
        crc, preload, archive, offset, length, term = struct.unpack_from("<IHHIIH", data, pos)
        pos += RECORD
        if term != TERMINATOR:
            errors.append(f"{path}: entry {len(entries)} has terminator 0x{term:04X}")
            return entries, errors
        entries.append((ext, path_field, name, crc, preload, archive, offset, length))
    if pos != end:
        errors.append(f"{path}: tree ended {end - pos} bytes short")
    return entries, errors


def archive_path(dir_path, index):
    stem, _ = os.path.splitext(dir_path)
    if stem.endswith("_dir"):
        stem = stem[: -len("_dir")]
    return f"{stem}_{index:03d}.vpk"


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    total_entries = total_extents = total_preload = 0
    by_extension = {}
    problems = []
    for root in argv[1:]:
        for base, _dirs, files in sorted(os.walk(root)):
            for name in sorted(files):
                if not name.endswith("_dir.vpk"):
                    continue
                dir_path = os.path.join(base, name)
                entries, errors = parse_tree(dir_path)
                problems.extend(errors)
                extent = preload = 0
                archives = set()
                for ext, _path, _name, _crc, pl, archive, _offset, length in entries:
                    extent += length
                    preload += pl
                    if archive != 0x7FFF:
                        archives.add(archive)
                missing = [
                    index for index in sorted(archives)
                    if not os.path.exists(archive_path(dir_path, index))
                ]
                print(
                    f"{os.path.relpath(dir_path, root)}: {len(entries)} entries, "
                    f"{extent} B in {len(archives)} archive(s), {preload} B preload"
                )
                if errors:
                    print(f"  parsed the tree up to entry {len(entries)}: {errors[0].split(': ', 1)[-1]}")
                if missing:
                    print(f"  missing archive files: {missing[:6]}{'...' if len(missing) > 6 else ''}")
                for ext, _p, _n, _c, _pl, _a, _o, length in entries:
                    key = f".{ext.lower()}" if ext else "(none)"
                    by_extension[key] = by_extension.get(key, 0) + length
                total_entries += len(entries)
                total_extents += extent
                total_preload += preload
    print(f"\ntotal: {total_entries} entries, {total_extents} B of entry extents, {total_preload} B preload")
    for ext, size in sorted(by_extension.items(), key=lambda item: -item[1])[:12]:
        print(f"  {ext:12s} {size:14d}")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for problem in problems[:10]:
            print("  " + problem)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
