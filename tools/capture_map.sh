#!/bin/sh
# Launch CSSO, wait for the map to actually load (console.log), place the camera
# and capture a screenshot. This is the reproducible replacement for sleeping a
# fixed number of seconds.
#
#   tools/capture_map.sh <csso root> <map> "<x y z>" <out.png> [timeout seconds]
#
# Requires cl_showpos so the chosen viewpoint is recorded in the log; the caller
# can read the last "pos" line afterwards.
set -eu
CSSO=${1:?usage: capture_map.sh <csso root> <map> "x y z" <out.png> [timeout]}
MAP=${2:?}
POS=${3:-0 0 0}
OUT=${4:?}
LIMIT=${5:-240}

case "$CSSO" in
[A-Za-z]:*) CSSO_WSL="/mnt/$(printf %s "$CSSO" | cut -c1 | tr A-Z a-z)$(printf %s "$CSSO" | cut -c3-)" ;;
*) CSSO_WSL=$CSSO ;;
esac
LOG="$CSSO_WSL/csso/console.log"
rm -f "$LOG"

( "$CSSO_WSL/csso_win64.exe" -game csso -dev -condebug -console -novid -windowed -w 1280 -h 720 \
	+sv_cheats 1 +map "$MAP" +noclip +cl_showpos 1 +setpos $POS >/dev/null 2>&1 & ) || true

waited=0
while [ "$waited" -lt "$LIMIT" ]; do
	sleep 2
	waited=$((waited + 2))
	[ -f "$LOG" ] || continue
	# The engine logs the level load and a spawn once the map is live.
	if grep -qiE "spawn server|Level .* loaded|Started map" "$LOG"; then
		break
	fi
done

sleep 3
powershell.exe -NoProfile -Command "\$ws=New-Object -ComObject WScript.Shell; \$ws.AppActivate('Source Offensive') | Out-Null; Start-Sleep -Seconds 1; Add-Type -AssemblyName System.Windows.Forms,System.Drawing; \$b=New-Object Drawing.Bitmap(1280,720); \$g=[Drawing.Graphics]::FromImage(\$b); \$g.CopyFromScreen(0,0,0,0,\$b.Size); \$b.Save('$OUT');" >/dev/null 2>&1 || true
grep -aoE "pos (-?[0-9.]+) (-?[0-9.]+) (-?[0-9.]+)" "$LOG" | tail -1 || true
powershell.exe -NoProfile -Command "Get-Process csso_win64 -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
echo "captured $OUT after ${waited}s"
