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
# The tools are Windows binaries but the shell is POSIX: keep Windows paths for
# the .exe calls and convert to /mnt/<drive>/... for mkdir and cp.
win_to_wsl() {
	case "$1" in
	[A-Za-z]:*) printf '/mnt/%s%s\n' "$(printf %s "$1" | cut -c1 | tr A-Z a-z)" "$(printf %s "$1" | cut -c3-)" ;;
	*) printf '%s\n' "$1" ;;
	esac
}
WORK_WSL=$(win_to_wsl "$WORK")
CSSO_WSL=$(win_to_wsl "$CSSO")
CONTENT_WSL=$(win_to_wsl "${CONTENT:-}")
mkdir -p "$WORK_WSL"
MAPCONV=${MAPCONV:-./mapconv}

"$MAPCONV" convert --input "$MAP" --output "$WORK/$NAME.vmf"

# Deterministic spectator camera for captures: a spawn entity at CAPTURE_POS.
# The converter itself never emits spawns; this is a test-only aid.
if [ -n "${CAPTURE_POS:-}" ]; then
	for cls in info_player_terrorist info_player_counterterrorist info_player_start; do
		cat >> "$WORK_WSL/$NAME.vmf" <<EOF
entity
{
	"classname" "$cls"
	"origin" "$CAPTURE_POS"
	"angles" "0 0 0"
}
EOF
	done
fi

if [ -n "${CONTENT:-}" ]; then
	"$MAPCONV" extract --input "$MAP" --content "$CONTENT" --output "$WORK/assets"
	mkdir -p "$CSSO_WSL/csso/materials"
	cp -r "$WORK_WSL"/assets/materials/* "$CSSO_WSL/csso/materials/" 2>/dev/null || true
	cp "$WORK_WSL"/assets/*.vtf "$CSSO_WSL/csso/materials/" 2>/dev/null || true
	for qc in "$WORK"/assets/"$NAME"/*.qc; do
		[ -f "$qc" ] || continue
		"$CSSO/win32/studiomdl.exe" -game "$CSSO/csso" -nop4 "$qc" >/dev/null 2>&1 || true
	done
fi

mkdir -p "$CSSO_WSL/csso/maps"
cp "$WORK_WSL/$NAME.vmf" "$CSSO_WSL/csso/maps/$NAME.vmf"
cd "$CSSO_WSL/csso/maps"

# -game must be relative here: the x64 tools fail to resolve the game root
# from an absolute path with spaces.
"$CSSO_WSL/bin/x64/vbsp.exe" -game .. "$NAME.vmf"
"$CSSO_WSL/bin/x64/vvis.exe" -fast -game .. "$NAME.bsp"
"$CSSO_WSL/bin/x64/vrad.exe" -fast -game .. "$NAME.bsp"

echo "built $CSSO/csso/maps/$NAME.bsp"
