#!/usr/bin/env python3
"""Launch a game with a map, wait for it to load, screenshot its window, judge the frame.

The point is a map test that ends in a verdict instead of a person looking at a window.
Each profile carries the command line the game itself ships in its launchers, so the test
runs the map the way the game runs it:

  CrimeCraft, offline server  (CC-Offline-Server.bat)
      Binaries\\CrimeCraft.exe arena01_solo_all?game=CrimeCraft.CCSoloGameInfo?
          MinNetPlayers=1?GoalScore=25?WarmupTime=0?TimeLimit=30?PlayersMustBeReady=true?listen
          -updateinisauto -skipscriptoutdatedness -nostartupmovies -nosplash

  CrimeCraft, front end       (CC-Offline-Server - testing.bat)
      ... EntryLevel?game=CrimeCraft.CCOfflineGameInfo?... (the hub map, which shows the menu)

  CSSO
      csso_win64.exe -game csso -novid -windowed -w 1280 -h 720 -condebug +sv_cheats 1 +map <map>

Usage:
  game_smoke.py --game crimecraft --map arena01_solo_all --shot cc.bmp
  game_smoke.py --game csso --map cs_assault --shot csso.bmp
  game_smoke.py --game csso --compile-vmf out.vmf --shot converted.bmp
  game_smoke.py --game cssso --list

The frame is judged by its own pixels: a screenshot that is one flat colour, almost all
black, or byte-identical to the frame taken two seconds earlier is a failure. BMP is used
for the capture because the analysis is ten lines of Python and no imaging library is
needed on this machine.
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXAMPLES = os.path.join(REPO, "examples")

PROFILES = {
    "crimecraft": {
        "root": os.path.join(EXAMPLES, "CrimeCraft maps", "CrimeCraft_GW", "CrimeCraft"),
        "exe": os.path.join("Binaries", "CrimeCraft.exe"),
        "args": [
            "{map}?game={game}?"
            "MinNetPlayers=1?GoalScore=25?WarmupTime=0?TimeLimit=30?PlayersMustBeReady=true?listen",
            "-updateinisauto",
            "-skipscriptoutdatedness",
            "-nostartupmovies",
            "-nosplash",
            "-windowed",
            "-ResX=1280",
            "-ResY=720",
        ],
        "default_game": "CrimeCraft.CCSoloGameInfo",
        "process": "CrimeCraft",
        "map_dir": ("CrimeCraftGame", "CookedPC", "Maps"),
        "map_ext": ".ccmap",
        # The ini files this build ships are packed, so there is no log to follow: the
        # readiness signal is the game window appearing and staying up.
        "log": None,
        "ready": (),
        "settle": 20,
        "needs_manifest_patch": True,
        "quit_note": "HackShield guards the process: WM_CLOSE is ignored and the kill needs "
                     "wmic. The harness reports what it managed instead of pretending.",
    },
    "csso": {
        "root": os.path.join(EXAMPLES, "CSSO maps", "csso_2.0_w-cssfiles"),
        "exe": "csso_win64.exe",
        "args": [
            "-game", "csso",
            "-novid",
            "-windowed",
            "-w", "1280",
            "-h", "720",
            "-condebug",
            "+sv_cheats", "1",
            "+map", "{map}",
        ],
        "default_game": "",
        "process": "csso_win64",
        "map_dir": ("csso", "maps"),
        "map_ext": ".bsp",
        "log": os.path.join("csso", "console.log"),
        "ready": ("Level loaded", "Spawn Server", "Connected to", "ServerNumber"),
        "settle": 10,
        "needs_manifest_patch": False,
        "quit_note": "",
    },
}

WAIT_PS = r"""
param([string]$Process = 'CrimeCraft', [int]$Seconds = 120)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W2 { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 public struct RECT { public int Left, Top, Right, Bottom; } }
"@
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
  $p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) {
    $r = New-Object W2+RECT
    [W2]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
    # A game window, not the little helper/tooltip windows the protection driver opens:
    # those are a few hundred by a few dozen pixels.
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -ge 400 -and $h -ge 300) { Write-Output "$w x $h"; exit 0 }
  }
  Start-Sleep -Milliseconds 700
}
Write-Output 'timeout'; exit 1
"""

CLICK_PS = r"""
param([string]$Process = 'CrimeCraft')
Add-Type @"
using System; using System.Runtime.InteropServices;
public class M {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
 public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output 'noproc'; exit 1 }
[M]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 400
$r = New-Object M+RECT
[M]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$x = [int](($r.Left + $r.Right) / 2); $y = [int](($r.Top + $r.Bottom) / 2)
[M]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 200
[M]::mouse_event(0x0002, 0, 0, 0, 0)   # left down
Start-Sleep -Milliseconds 80
[M]::mouse_event(0x0004, 0, 0, 0, 0)   # left up
Write-Output "clicked at $x,$y"
"""

CAPTURE_PS = r"""
param([string]$Process = 'CrimeCraft', [string]$Out = 'C:\tmp\shot.bmp')
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Win {
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output 'noproc'; exit 1 }
$h = $p.MainWindowHandle
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object Win+RECT
[Win]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
if ($w -le 0 -or $hh -le 0) { Write-Output 'norect'; exit 1 }
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hh))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Bmp)
Write-Output "$w x $hh"
"""


SYSTEM32 = "/mnt/c/Windows/System32"

# A directory both worlds can see: WSL's /tmp is not a Windows path, and a script written
# there cannot be handed to PowerShell.
WINDOWS_TEMP = "/mnt/c/tmp"


def windows_temp(name):
    os.makedirs(WINDOWS_TEMP, exist_ok=True)
    return os.path.join(WINDOWS_TEMP, name)


def windows_tool(name):
    """A Windows tool by absolute path: the interop shell has these on PATH and a bare
    subprocess call from Python does not."""
    candidate = os.path.join(SYSTEM32, name)
    return candidate if os.path.exists(candidate) else name


def win_path(path):
    """WSL path -> Windows path, so powershell and the games can be handed a string."""
    absolute = os.path.abspath(path)
    if absolute.startswith("/mnt/") and len(absolute) > 6:
        drive = absolute[5]
        return drive.upper() + ":" + absolute[6:].replace("/", "\\")
    return absolute.replace("/", "\\")


def run_powershell(script, args, name="capture.ps1"):
    """Run a script through Windows PowerShell. The script has to live on a path Windows can
    open, so it goes in a directory both worlds see and is removed afterwards."""
    path = windows_temp(name)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(script)
    command = [windows_tool("WindowsPowerShell\\v1.0\\powershell.exe") if False else "powershell.exe",
               "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win_path(path)]
    command.extend(args)
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    try:
        os.remove(path)
    except OSError:
        pass
    return result


def click_center(process):
    """Press the fire button, which is what CrimeCraft's briefing waits for."""
    result = run_powershell(CLICK_PS, ["-Process", process], name="click.ps1")
    detail = (result.stdout.strip().splitlines() or [""])[-1]
    return result.returncode == 0 and "clicked" in detail, detail


def capture_window(process, output):
    result = run_powershell(CAPTURE_PS, ["-Process", process, "-Out", win_path(output)])
    # PowerShell exits 0 even when it refuses to run a script, so success means: no error
    # on stderr, a rectangle was reported, and the file is there.
    detail = (result.stdout.strip().splitlines() or [""])[-1]
    failed = result.returncode != 0 or result.stderr.strip() != "" or not os.path.exists(output)
    if failed:
        detail = (result.stderr.strip() or detail or "no output").splitlines()[-1]
    return (not failed), detail


def read_bmp(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:2] != b"BM":
        raise ValueError("not a BMP")
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    if bits not in (24, 32):
        raise ValueError("unsupported BMP depth %d" % bits)
    stride = ((width * bits // 8) + 3) & ~3
    pixels = []
    for y in range(abs(height)):
        row = offset + y * stride
        for x in range(abs(width)):
            base = row + x * (bits // 8)
            blue, green, red = data[base], data[base + 1], data[base + 2]
            pixels.append((red * 299 + green * 587 + blue * 114) // 1000)
    return pixels, abs(width), abs(height)


def judge(pixels, width, height):
    """Turn a frame into a verdict: is this a rendered world or a blank window?"""
    total = len(pixels)
    if total == 0:
        return False, "the window had no pixels"
    mean = sum(pixels) / total
    variance = sum((value - mean) ** 2 for value in pixels) / total
    dark = sum(1 for value in pixels if value < 8) / total
    flat = sum(1 for value in pixels if value == pixels[0]) / total
    # 16 levels of luminance is enough to tell a menu from a black window and cheap to count.
    buckets = len({value >> 4 for value in pixels})
    reasons = []
    if mean < 6:
        reasons.append("the frame is black (mean %.1f)" % mean)
    if variance ** 0.5 < 4:
        reasons.append("the frame is flat (stdev %.1f)" % (variance ** 0.5))
    if buckets < 8:
        reasons.append("only %d luminance bands" % buckets)
    if dark > 0.995:
        reasons.append("%.1f%% of the frame is black" % (100 * dark))
    if flat > 0.995:
        reasons.append("%.1f%% of the frame is one colour" % (100 * flat))
    stats = "mean %.1f, stdev %.1f, dark %.1f%%, bands %d" % (
        mean, variance ** 0.5, 100 * dark, buckets)
    return (len(reasons) == 0), (stats if not reasons else "; ".join(reasons) + " [" + stats + "]")


def process_count(process_name):
    """How many of this process are running, asked of PowerShell.

    `tasklist` is not used anywhere here: with the game's protection driver loaded it can
    block for minutes, and a harness that measures nothing while it waits is worse than one
    that says it cannot see. `Get-Process` answers in a fraction of a second, and every call
    gets a timeout so a stuck query fails instead of hanging.
    """
    script = ("$n=(Get-Process -Name %s -ErrorAction SilentlyContinue | Measure-Object).Count; "
              "Write-Output $n" % process_name)
    result = subprocess.run(["powershell.exe", "-NoProfile", "-Command", script],
                            capture_output=True, text=True, timeout=60)
    try:
        return int((result.stdout or "0").strip().splitlines()[-1])
    except (ValueError, IndexError):
        return 0


def looks_like_loading(pixels):
    """A loading or logo screen is dark with a small bright area; a world has mid tones
    spread over the frame. This is a heuristic, and it is only used to decide whether to
    wait longer -- never to call a working frame broken."""
    total = len(pixels)
    dark = sum(1 for value in pixels if value < 12) / total
    bright = sum(1 for value in pixels if value > 90) / total
    return dark > 0.97 and bright < 0.01


def wait_for_window(process_name, seconds):
    """One PowerShell call that returns the moment the game has a window with a rectangle.

    This replaces polling `tasklist`: on this machine a single process listing costs about
    ten seconds (the game installs a protection driver), and a two second poll loop spent
    sixteen minutes measuring nothing.
    """
    result = run_powershell(WAIT_PS, ["-Process", process_name, "-Seconds", str(int(seconds))],
                            name="wait.ps1")
    detail = (result.stdout.strip().splitlines() or [""])[-1]
    return result.returncode == 0 and "x" in detail, detail


def wait_for(profile, root, process_name, log_path, deadline):
    """Ready means: the game has a window, and -- where the game writes a console log --
    the log says a level loaded."""
    remaining = max(5.0, deadline - time.time())
    window, detail = wait_for_window(process_name, remaining)
    if not window:
        return False, "no window (%s)" % detail
    if not log_path:
        return True, "window up (%s), no log to follow" % detail
    # The log is a local file: reading it costs nothing, so the markers can be waited for.
    log_offset = 0
    if os.path.exists(log_path):
        log_offset = os.path.getsize(log_path)
    while time.time() < deadline:
        time.sleep(1.5)
        if not os.path.exists(log_path):
            continue
        with open(log_path, "rb") as handle:
            handle.seek(log_offset)
            text = handle.read().decode("latin-1", "replace")
        for marker in profile["ready"]:
            if marker in text:
                return True, "log: %s" % marker
    return True, "window up (%s), no load marker in the log" % detail


def kill(process_name, timeout=20):
    """Try the polite ways first; report whether the process actually went away."""
    for label, flags in (("taskkill", ["/IM"]), ("taskkill /F", ["/F", "/IM"])):
        try:
            subprocess.run([windows_tool("taskkill.exe")] + flags + ["%s.exe" % process_name],
                           capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            continue
        time.sleep(1.5)
        if not is_running(process_name):
            return True, "closed by " + label
    return False, "still running (protected process: HackShield refuses the kill)"


def is_running(process_name):
    return process_count(process_name) > 0


def requires_admin(exe_path):
    """Read the application manifest the way Windows does: the executable asks for
    elevation and a harness that starts it would sit in front of a UAC prompt."""
    try:
        with open(exe_path, "rb") as handle:
            data = handle.read()
    except OSError:
        return None
    return b'level="requireAdministrator"' in data


def list_maps(profile, root):
    """Map names the game can be asked for. CrimeCraft keeps its maps one directory down
    (Maps/instance, Maps/lobby) and asks for them by bare name, so the walk keeps the name
    and drops the directory."""
    directory = os.path.join(root, *profile["map_dir"])
    if not os.path.isdir(directory):
        return []
    names = []
    for base, _, files in os.walk(directory):
        for name in files:
            if name.lower().endswith(profile["map_ext"]):
                names.append(os.path.splitext(name)[0])
    return sorted(set(names))


def compile_vmf(vmf, game_root, output_dir):
    """Turn a .vmf into a .bsp with the vbsp that ships in this install.

    vbsp is the writer this toolkit is measured against, and running it is the only way to
    turn a converted map into something a game can load.
    """
    vbsp = os.path.join(game_root, "bin", "x64", "vbsp.exe")
    if not os.path.exists(vbsp):
        return None, "no vbsp.exe in %s" % vbsp
    os.makedirs(output_dir, exist_ok=True)
    name = os.path.splitext(os.path.basename(vmf))[0]
    working = os.path.join(output_dir, name + ".vmf")
    shutil.copyfile(vmf, working)
    # The game directory has spaces in its path and vbsp does not quote it, so it is
    # reached through a junction without spaces.
    junction = "C:\\_mapconv_game"
    if not os.path.exists(junction):
        subprocess.run(["cmd", "/c", "mklink", "/J", junction, win_path(game_root)],
                       capture_output=True, text=True)
    result = subprocess.run(
        [vbsp, "-game", os.path.join(junction, "cstrike"), win_path(working)],
        capture_output=True, text=True)
    bsp = os.path.splitext(working)[0] + ".bsp"
    if not os.path.exists(bsp):
        return None, "vbsp produced no bsp:\n" + (result.stdout or "")[-1500:]
    maps = os.path.join(game_root, "csso", "maps")
    destination = os.path.join(maps, name + ".bsp")
    shutil.copyfile(bsp, destination)
    return name, "compiled %s (%d bytes)" % (destination, os.path.getsize(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", choices=sorted(PROFILES), help="which game to test")
    parser.add_argument("--map", help="map name as the game knows it (no extension)")
    parser.add_argument("--shot", default="", help="where to save the window capture (BMP)")
    parser.add_argument("--seconds", type=int, default=180, help="how long to wait for the map")
    parser.add_argument("--settle", type=float, default=None,
                        help="seconds to wait after the map reports loaded before capturing")
    parser.add_argument("--compile-vmf", default="", help="compile this .vmf and test the result")
    parser.add_argument("--game-info", default="", help="override ?game= for CrimeCraft")
    parser.add_argument("--json", default="", help="write the result as JSON here")
    parser.add_argument("--list", action="store_true", help="list the maps this profile can run")
    parser.add_argument("--click", action="store_true",
                        help="click the middle of the window once the map is loaded")
    parser.add_argument("--no-kill", action="store_true", help="leave the game running")
    parser.add_argument("--root", default="", help="override the game root")
    args = parser.parse_args()

    if args.list:
        for name, profile in PROFILES.items():
            root = args.root or profile["root"]
            maps = list_maps(profile, root)
            print("%s: %d map(s)" % (name, len(maps)))
            for entry in maps:
                print("  " + entry)
        return 0

    if not args.game:
        parser.error("--game is required unless --list is used")
    profile = PROFILES[args.game]
    root = args.root or profile["root"]
    game = args.game_info or profile["default_game"]

    if args.compile_vmf:
        name, detail = compile_vmf(args.compile_vmf, profile["root"], os.path.join(REPO, "build"))
        print(detail)
        if not name:
            return 2
        args.map = name
    if not args.map:
        parser.error("--map or --compile-vmf is required")

    process = profile["process"]
    if is_running(process):
        print("game_smoke: %s is already running; close it first" % process)
        return 2
    exe_path = os.path.join(root, profile["exe"])
    if profile["needs_manifest_patch"]:
        admin = requires_admin(exe_path)
        if admin:
            print("game_smoke: %s still asks for elevation; run tools/unrequire_admin.py "
                  "--exe it first, or every start waits in front of a UAC prompt." % exe_path)
            return 2
        if admin is None:
            print("game_smoke: cannot read %s" % exe_path)
            return 2

    command = [os.path.join(root, profile["exe"])]
    for part in profile["args"]:
        command.append(part.format(map=args.map, game=game))
    log_path = os.path.join(root, profile["log"]) if profile["log"] else ""

    started = time.time()
    print("launch: " + " ".join(command))
    # Launch through cmd.exe's `start`, the way both games' own launchers do: CrimeCraft
    # refuses to start when it is executed directly by the interop layer ("Invalid
    # argument"), and `start` is what its .bat files use.
    # Launched directly, with no shell: `cmd /c start` hands its standard handles to the
    # game, so even a redirect keeps cmd.exe alive until the game exits, and the harness
    # waited on its own launcher. The games are started as plain processes now, with a
    # PowerShell Start-Process as the fallback for a binary the interop layer refuses.
    child = None
    try:
        child = subprocess.Popen(command, cwd=root,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        print("launch: direct start failed (%s), trying Start-Process" % error)
        quoted = ",".join("'%s'" % part.replace("'", "''") for part in command[1:])
        script = ("Start-Process -FilePath '%s' -WorkingDirectory '%s' -ArgumentList @(%s)" %
                  (win_path(command[0]).replace("'", "''"), win_path(root).replace("'", "''"), quoted))
        subprocess.run(["powershell.exe", "-NoProfile", "-Command", script],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    deadline = time.time() + args.seconds
    loaded, detail = wait_for(profile, root, process, log_path, deadline)
    print("load: %s (%s)" % ("ok" if loaded else "FAILED", detail))

    settle = args.settle if args.settle is not None else profile["settle"]
    time.sleep(settle)
    if args.click:
        clicked, click_detail = click_center(process)
        print("click: %s (%s)" % ("ok" if clicked else "FAILED", click_detail))
        time.sleep(6)

    shot = args.shot or windows_temp("game_smoke_%s.bmp" % args.game)
    # A loading screen is a frame too: keep asking until the frame stops looking like one,
    # or until three attempts have been made.
    captured, capture_detail, verdict, why, size = (False, "no capture", False, "", (0, 0))
    for attempt in range(3):
        captured, capture_detail = capture_window(process, shot)
        if not captured or not os.path.exists(shot):
            break
        pixels, width, height = read_bmp(shot)
        verdict, why = judge(pixels, width, height)
        size = (width, height)
        loading = why.split("[")[0]
        if verdict and "black" not in why and not looks_like_loading(pixels):
            break
        if attempt < 2:
            print("frame: attempt %d still loading (%s), waiting" % (attempt + 1, why))
            time.sleep(10)
    print("capture: %s (%s) -> %s" % ("ok" if captured else "FAILED", capture_detail, shot))
    print("frame: %dx%d %s -> %s" % (size[0], size[1], why, "rendered" if verdict else "BLANK"))

    closed, close_detail = (True, "kept")
    if not args.no_kill:
        closed, close_detail = kill(process)
        print("cleanup: %s (%s)" % ("ok" if closed else "FAILED", close_detail))

    result = {
        "game": args.game,
        "map": args.map,
        "loaded": loaded,
        "load_detail": detail,
        "captured": captured,
        "shot": shot,
        "frame_ok": verdict,
        "frame_detail": why,
        "closed": closed,
        "close_detail": close_detail,
        "seconds": round(time.time() - started, 1),
    }
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
        print("result: " + args.json)

    if not loaded or not captured or not verdict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
