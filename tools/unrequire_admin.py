#!/usr/bin/env python3
"""Stop a Windows executable from demanding elevation by patching its manifest.

CrimeCraft's `Binaries\\CrimeCraft.exe` and `ClientLauncher.exe` embed an application
manifest whose `<requestedExecutionLevel level="requireAdministrator">` makes Windows show a
UAC prompt on every start. The game itself does not need it: it is a 32-bit single-player
program that reads and writes only inside its own directory, and the prompt is what stops a
test harness (and a person) from starting it unattended.

The patch is textual and length preserving, because the manifest lives in a PE resource
whose size is declared in the resource directory -- and the resource directory is part of
the section headers. Writing a shorter level name would need every size after it fixed up;
writing the same number of bytes needs nothing:

    level="requireAdministrator"     28 bytes
    level="asInvoker"              28 bytes   (11 spaces of padding)

`asInvoker` is the level that means "run with the rights the caller already has", and the
whitespace keeps the tag legal, so the manifest still parses and the resource still has
exactly the size it declares.

Usage:
  unrequire_admin.py --exe <exe>            patch, keeping a backup the first time
  unrequire_admin.py --exe <exe> --dry-run  say what would change and stop
  unrequire_admin.py --exe <exe> --restore  put the backup back
"""

import argparse
import hashlib
import os
import shutil
import sys

WANTED = b'level="requireAdministrator"'
# Padding with whitespace, not with a comment: XML allows space between attributes and
# before the tag close, but a comment is not allowed inside a start tag -- the first
# version of this patch used one, and Windows reported a broken side-by-side configuration.
REPLACEMENT = b'level="asInvoker"' + b" " * (len(WANTED) - len(b'level="asInvoker"'))
# Both sides have to be the same length: the resource size is declared elsewhere and is not
# ours to change.
assert len(WANTED) == len(REPLACEMENT), (len(WANTED), len(REPLACEMENT))

ALREADY = b'level="asInvoker"'


def manifest_is_valid(data):
    """Check the manifest the same way Windows does before trusting it with 36 MB of exe:
    find the assembly element and parse it as XML."""
    import xml.etree.ElementTree as ElementTree
    start = data.find(b"<assembly")
    end = data.find(b"</assembly>")
    if start < 0 or end < 0:
        return False, "no assembly element"
    text = data[start:end + len(b"</assembly>")].decode("utf-8", "replace")
    try:
        ElementTree.fromstring(text)
    except ElementTree.ParseError as error:
        return False, "manifest does not parse: %s" % error
    return True, "manifest parses"


def digest(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def patch(path, dry_run):
    backup = path + ".require-admin.bak"
    with open(path, "rb") as handle:
        data = handle.read()
    if ALREADY in data:
        print("%s: already asInvoker, nothing to do" % path)
        return 0
    count = data.count(WANTED)
    if count == 0:
        print("%s: no requireAdministrator manifest found" % path)
        return 1
    if count > 1:
        print("%s: %d manifests carry the level, refusing to patch blind" % (path, count))
        return 1
    at = data.index(WANTED)
    patched = data[:at] + REPLACEMENT + data[at + len(WANTED):]
    if len(patched) != len(data):
        print("%s: the patch would change the length, refusing" % path)
        return 1
    valid, why = manifest_is_valid(patched)
    print("%s: requireAdministrator -> asInvoker at offset %d (sha256 %s)" % (path, at, digest(path)[:16]))
    print("  %s" % why)
    if not valid:
        print("  refusing to write a manifest Windows will reject")
        return 1
    if dry_run:
        print("  dry run: nothing written")
        return 0
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print("  backup: %s" % backup)
    with open(path, "wb") as handle:
        handle.write(patched)
    print("  written, sha256 %s" % digest(path)[:16])
    return 0


def restore(path):
    backup = path + ".require-admin.bak"
    if not os.path.exists(backup):
        print("%s: no backup to restore" % path)
        return 1
    shutil.copy2(backup, path)
    print("%s: restored from %s" % (path, backup))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exe", required=True, help="the executable whose manifest to patch")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    if not os.path.exists(args.exe):
        print("%s: not found" % args.exe)
        return 2
    if args.restore:
        return restore(args.exe)
    return patch(args.exe, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
