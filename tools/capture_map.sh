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
	+sv_cheats 1 +map "$MAP" +noclip +cl_showpos 1 +bind f5 "setpos $POS" >/dev/null 2>&1 & ) || true

waited=0
loaded=0
while [ "$waited" -lt "$LIMIT" ]; do
	sleep 2
	waited=$((waited + 2))
	[ -f "$LOG" ] || continue
	# "Spawn Server" is logged before the renderer resources are ready, so it
	# only arms the stability check; the map is considered live once the log
	# has stopped growing for six seconds after at least 20 seconds.
	if [ "$loaded" -eq 0 ] && grep -qi "Spawn Server" "$LOG"; then
		loaded=$waited
	fi
	if [ "$loaded" -gt 0 ] && [ $((waited - loaded)) -ge 20 ]; then
		size_a=$(wc -c < "$LOG")
		sleep 6
		waited=$((waited + 6))
		size_b=$(wc -c < "$LOG")
		if [ "$size_a" -eq "$size_b" ]; then
			break
		fi
	fi
done

sleep 2
powershell.exe -NoProfile -Command "\$ws=New-Object -ComObject WScript.Shell; \$ws.AppActivate('Source Offensive') | Out-Null; Start-Sleep -Seconds 1; Add-Type -AssemblyName System.Windows.Forms,System.Drawing; Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport(\"user32.dll\")] public static extern IntPtr FindWindow(string c, string n);
  [DllImport(\"user32.dll\")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
}
'@; \$proc=Get-Process | Where-Object { \$_.MainWindowTitle -like '*Source Offensive*' } | Select-Object -First 1; if (\$proc) { \$ws.AppActivate(\$proc.Id) | Out-Null; Start-Sleep -Seconds 1; \$ws.SendKeys('{ENTER}') | Out-Null; Start-Sleep -Seconds 1; \$ws.SendKeys('6') | Out-Null; Start-Sleep -Milliseconds 500; \$ws.SendKeys('{F5}') | Out-Null; Start-Sleep -Seconds 1; \$h=\$proc.MainWindowHandle } else { \$h=[IntPtr]::Zero }; \$r=New-Object W+RECT; if (\$h -ne [IntPtr]::Zero -and [W]::GetWindowRect(\$h,[ref]\$r)) { \$w=\$r.R-\$r.L; \$hh=\$r.B-\$r.T; \$b=New-Object Drawing.Bitmap(\$w,\$hh); \$g=[Drawing.Graphics]::FromImage(\$b); \$g.CopyFromScreen(\$r.L,\$r.T,0,0,\$b.Size); \$b.Save('$OUT'); } else { \$b=New-Object Drawing.Bitmap(1280,720); \$g=[Drawing.Graphics]::FromImage(\$b); \$g.CopyFromScreen(0,0,0,0,\$b.Size); \$b.Save('$OUT'); }" >/dev/null 2>&1 || true
grep -aoE "pos (-?[0-9.]+) (-?[0-9.]+) (-?[0-9.]+)" "$LOG" | tail -1 || true
powershell.exe -NoProfile -Command "Get-Process csso_win64 -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1 || true
echo "captured $OUT after ${waited}s"
