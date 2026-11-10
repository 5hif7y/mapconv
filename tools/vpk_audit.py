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

Usage: tools/vpk_audit.py [--crc] [--limit N] <game root> [more roots...]

With --crc every entry is read from its archive and its CRC32 compared with the
one the tree records. A version 2 VPK stores bytes uncompressed, so this is the
whole content check; --limit keeps it to the first N entries per archive.
"""
import os
import struct
import sys
import zlib

HEADER = 28
RECORD = 18
TERMINATOR = 0xFFFF


def read_cstring(data, pos):
    end = data.index(b"\0", pos)
    return data[pos:end].decode("latin1"), end + 1


def parse_tree(path):
    """Returns (entries, errors). An entry is (ext, path, name, crc, preload,
    archive, offset, length).

    The tree is nested: an extension, then for that extension each directory, then
    for that directory each file. An empty name closes the file list of a
    directory, an empty directory closes the extension and an empty extension
    closes the tree. A file without an extension is stored under a single space.

    Reading the nesting as "count the leading NULs" works only while those NULs
    happen to be contiguous, which is why the earlier rule stopped in
    cstrike_pak_dir.vpk: after "snd" and "reslists" come an empty name and an empty
    path, and the next bytes are the extension "lst" with the directory
    "scripts" -- until that point every empty name had been followed by a name.
    """
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

    def string():
        nonlocal pos
        if pos >= end:
            raise EOFError("string starts past the end of the tree")
        stop = data.find(b"\0", pos, end)
        if stop < 0:
            raise EOFError("unterminated string in the tree")
        text = data[pos:stop].decode("latin1")
        pos = stop + 1
        return text

    try:
        ext = string()
        while ext:
            directory = string()
            while directory:
                while True:
                    name = string()
                    if not name:
                        break
                    if pos + RECORD > end:
                        errors.append(f"{path}: entry header past the tree")
                        return entries, errors
                    crc, preload, archive, offset, length, term = struct.unpack_from("<IHHIIH", data, pos)
                    pos += RECORD
                    if term != TERMINATOR:
                        errors.append(f"{path}: entry {len(entries)} has terminator 0x{term:04X}")
                        return entries, errors
                    stored_ext = "" if ext == " " else ext
                    entries.append((stored_ext, directory, name, crc, preload, archive, offset, length))
                directory = string()
            ext = string()
    except EOFError as problem:
        errors.append(f"{path}: {problem} at entry {len(entries)}")
        return entries, errors
    if pos != end:
        errors.append(f"{path}: tree ended {end - pos} bytes short")
    return entries, errors


def archive_path(dir_path, index):
    stem, _ = os.path.splitext(dir_path)
    if stem.endswith("_dir"):
        stem = stem[: -len("_dir")]
    return f"{stem}_{index:03d}.vpk"


def verify_crc(dir_path, entries, limit):
    """Reads each entry from its archive and compares the CRC32 the tree records.
    Returns (checked, bytes_read, failures)."""
    checked = bytes_read = 0
    failures = []
    handles = {}
    try:
        for ext, directory, name, crc, _preload, archive, offset, length in entries:
            if limit is not None and checked >= limit:
                break
            if archive == 0x7FFF:
                # The payload lives inside the directory file itself.
                source = dir_path
                base = HEADER + struct.unpack_from("<I", open(dir_path, "rb").read(4 + 8))[0] if False else None
            else:
                source = archive_path(dir_path, archive)
            handle = handles.get(source)
            if handle is None:
                try:
                    handle = open(source, "rb")
                except OSError as problem:
                    failures.append(f"{os.path.basename(source)}: {problem}")
                    handles[source] = False
                    continue
                handles[source] = handle
            if handle is False:
                continue
            handle.seek(offset)
            payload = handle.read(length)
            if len(payload) != length:
                failures.append(f"{ext}/{directory}/{name}: {length} bytes asked, {len(payload)} read")
                continue
            actual = zlib.crc32(payload) & 0xFFFFFFFF
            checked += 1
            bytes_read += length
            if actual != crc:
                failures.append(f"{ext}/{directory}/{name}: crc 0x{crc:08X} recorded, 0x{actual:08X} computed")
    finally:
        for handle in handles.values():
            if handle:
                handle.close()
    return checked, bytes_read, failures


def main(argv):
    args = [item for item in argv[1:] if not item.startswith("--")]
    crc_check = "--crc" in argv
    limit = None
    for index, item in enumerate(argv):
        if item == "--limit" and index + 1 < len(argv):
            limit = int(argv[index + 1])
            args = [value for value in args if value != argv[index + 1]]
    if not args:
        print(__doc__)
        return 2
    argv = [argv[0]] + args
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
                out_of_bounds = 0
                for ext, directory, name, _crc, _pl, archive, offset, length in entries:
                    if archive == 0x7FFF:
                        continue
                    source = archive_path(dir_path, archive)
                    try:
                        if offset + length > os.path.getsize(source):
                            out_of_bounds += 1
                    except OSError:
                        pass
                if out_of_bounds:
                    problems.append(f"{os.path.relpath(dir_path, root)}: {out_of_bounds} entries past the end of their archive")
                if crc_check:
                    checked, bytes_read, failures = verify_crc(dir_path, entries, limit)
                    print(f"  crc: {checked} entries, {bytes_read} B verified, {len(failures)} failure(s)")
                    problems.extend(failures[:5])
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
