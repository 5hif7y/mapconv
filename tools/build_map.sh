#!/bin/sh
# Convert a UE3 .ccmap and compile it with the CSSO Source toolchain.
#
#   tools/build_map.sh <map.ccmap> <csso root> [workdir]
#
# Environment:
#   MAPCONV  path to mapconv (default: ./mapconv)
#   CONTENT  CookedPC directory used to resolve referenced meshes/materials
#
# The CSSO install keeps a working vbsp/vvis/vrad under bin/x64; the win32
# builds report a false leak even for a hand-written cube, so never use them.
set -eu

MAP=${1:?usage: build_map.sh <map.ccmap> <csso root> [workdir]}
CSSO=${2:?usage: build_map.sh <map.ccmap> <csso root> [workdir]}
WORK=${3:-$(mktemp -d)}
NAME=$(basename "$MAP" .ccmap)
MAPCONV=${MAPCONV:-./mapconv}

"$MAPCONV" convert --input "$MAP" --output "$WORK/$NAME.vmf"

if [ -n "${CONTENT:-}" ]; then
	"$MAPCONV" extract --input "$MAP" --content "$CONTENT" --output "$WORK/assets"
	mkdir -p "$CSSO/csso/materials"
	cp -r "$WORK"/assets/materials/* "$CSSO/csso/materials/" 2>/dev/null || true
	cp "$WORK"/assets/*.vtf "$CSSO/csso/materials/" 2>/dev/null || true
	for qc in "$WORK"/assets/"$NAME"/*.qc; do
		[ -f "$qc" ] || continue
		"$CSSO/win32/studiomdl.exe" -game "$CSSO/csso" -nop4 "$qc" >/dev/null 2>&1 || true
	done
fi

mkdir -p "$CSSO/csso/maps"
cp "$WORK/$NAME.vmf" "$CSSO/csso/maps/$NAME.vmf"
cd "$CSSO/csso/maps"

# -game must be relative here: the x64 tools fail to resolve the game root
# from an absolute path with spaces.
"$CSSO/bin/x64/vbsp.exe" -game .. "$NAME.vmf"
"$CSSO/bin/x64/vvis.exe" -fast -game .. "$NAME.bsp"
"$CSSO/bin/x64/vrad.exe" -fast -game .. "$NAME.bsp"

echo "built $CSSO/csso/maps/$NAME.bsp"
