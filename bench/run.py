#!/usr/bin/env python3
"""Compares Plum with Ghostty on this Mac and records every sample.

usage: run.py <phase>... [--out DIR] [--quick]
phases: launch throughput latency memory tabs   (or "all"), plus idle

Both apps are measured from the outside with the same tool (plumbench), in
turn, with their window frontmost and visible. Each phase writes one CSV into
the output folder; summarize.py turns the folder into a report.

The apps take keyboard focus while this runs. Samples taken while another
app was frontmost are marked and left out of the summary.
"""
import csv
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BENCH)
TOOL = os.path.join(BENCH, "plumbench")
PLUM = os.path.join(ROOT, "build", "Plum.app")
GHOSTTY = "/Applications/Ghostty.app"
WORK = os.path.join(tempfile.gettempdir(), "plum-bench")
STATE = os.path.join(WORK, "state")
DATA = os.path.join(WORK, "data")
DATASETS = ["ascii", "scrolling", "dense_cells", "unicode", "cursor_motion", "scroll_region", "sync_tui"]

launched = []


def tool(*args, check=True):
    result = subprocess.run([TOOL, *map(str, args)], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"plumbench {' '.join(map(str, args))}: {result.stderr.strip()}")
    return result.stdout.strip() or result.stderr.strip()


def fields(line):
    return dict(pair.split("=", 1) for pair in line.split())


def load():
    return os.getloadavg()[0]


def kill(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if pid in launched:
        launched.remove(pid)
    time.sleep(1.2)


def cleanup():
    for pid in list(launched):
        kill(pid)


# ---- Plum

def plum_socket():
    preferred = os.path.join(STATE, "plum.sock")
    if len(preferred.encode()) < 100:
        return preferred
    return subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip() + "plum.sock"


def plum(command):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(plum_socket())
        s.sendall(f"debug {command}\n".encode())
        data = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            data += chunk
    return data.decode(errors="replace").rstrip("\n")


def prepare_work():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(STATE)
    repo = os.path.join(WORK, "repo")
    os.makedirs(repo)
    git = ["git", "-C", repo, "-c", "user.email=bench@example.com", "-c", "user.name=bench"]
    subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
    with open(os.path.join(repo, "README.md"), "w") as f:
        f.write("bench\n")
    subprocess.run([*git, "add", "."], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "init"], check=True)
    state = {
        "projects": [{"id": "11111111-1111-1111-1111-111111111111", "name": "repo", "path": repo, "baseBranch": "",
                      "copyPatterns": [], "setupCommand": "", "agentCommand": ""}],
        "workspaces": [],
        "settings": {"fontName": "Menlo", "fontSize": 13, "workspaceRoot": os.path.join(WORK, "ws"), "branchPrefix": ""},
    }
    with open(os.path.join(STATE, "state.json"), "w") as f:
        json.dump(state, f)


def visible(pid):
    """Brings the app forward and returns its window details, or None if the
    window is not actually on screen (other Space, other app in full screen)."""
    for _ in range(6):
        tool("activate", pid, check=False)
        line = tool("window", pid, check=False)
        info = fields(line) if "onscreen=" in line else {}
        if info.get("onscreen") == "yes" and tool("activate", pid, check=False) == "frontmost":
            return info
        time.sleep(0.4)
    return None


home = {}  # where Plum's window opened; every measured window is put on that display


def require_visible(app, pid):
    """Makes sure the app is frontmost, on screen, and on the same display
    as every other measurement (memory and frame timing depend on the display)."""
    info = visible(pid)
    if info is None:
        raise RuntimeError(f"{app}: window is not frontmost and on screen, so it would not be drawing")
    if home and info.get("display") != home["display"]:
        tool("place", pid, home["x"], home["y"], check=False)
        time.sleep(1)
        info = visible(pid)
        if info is None or info.get("display") != home["display"]:
            raise RuntimeError(f"{app}: could not bring its window to display {home['display']}")
    return info


def launch_plum(debug=True):
    # Forget the remembered window position so the window opens on the
    # display in use, the same one Ghostty picks.
    subprocess.run(["defaults", "delete", "dev.plum.Plum", "NSWindow Frame PlumMainWindow"], capture_output=True)
    # PLUM_DEBUG_OCCLUSION keeps the app's real drawing rule (draw only while
    # visible); plain debug mode would draw even when hidden.
    env = ["--env", f"PLUM_STATE_DIR={STATE}"]
    if debug:
        env += ["--env", "PLUM_DEBUG=1", "--env", "PLUM_DEBUG_OCCLUSION=1"]
    info = fields(tool("launch", PLUM, "--activate", *env))
    launched.append(int(info["pid"]))
    return info


def launch_ghostty(grid, extra=(), command=None):
    args = ["--window-save-state=never", "--confirm-close-surface=false", "--quit-after-last-window-closed=true",
            "--auto-update=off", "--font-family=Menlo", "--font-size=13",
            f"--window-width={grid[0]}", f"--window-height={grid[1]}", *extra]
    if command:
        args += ["-e", *command]
    info = fields(tool("launch", GHOSTTY, "--activate", "--", *args))
    launched.append(int(info["pid"]))
    return info


def plum_grid():
    info = launch_plum()
    time.sleep(2.5)
    window = require_visible("plum", int(info["pid"]))
    home.update(display=window["display"], x=window["x"], y=window["y"], scale=window["scale"], refresh=window["refresh"])
    tab = json.loads(plum("state"))["tabs"][0]
    kill(int(info["pid"]))
    return tab["cols"], tab["rows"]


def frontmost(pid):
    return tool("activate", pid, check=False) == "frontmost"


def wait_for(path, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.01)
    return False


def writer(out, name, header):
    f = open(os.path.join(out, name + ".csv"), "w", newline="")
    w = csv.writer(f)
    w.writerow(header)
    return f, w


# ---- Phases

def phase_launch(out, grid, runs):
    """Time from asking macOS to open the app until its window is on screen
    and until it has started the shell."""
    f, w = writer(out, "launch", ["app", "run", "registered_ms", "window_ms", "child_ms", "display", "valid", "load1"])
    for run in range(runs + 1):  # run 0 warms the file cache and is not counted
        for app in (("plum", "ghostty") if run % 2 else ("ghostty", "plum")):
            info = launch_plum(debug=False) if app == "plum" else launch_ghostty(grid)
            time.sleep(1)
            window = fields(tool("window", info["pid"], check=False) or "onscreen=no")
            valid = window.get("onscreen") == "yes" and float(info["window_ms"]) > 0
            w.writerow([app, run, info["registered_ms"], info["window_ms"], info["child_ms"], window.get("display", ""),
                        "yes" if valid else "no", f"{load():.1f}"])
            f.flush()
            print(f"launch {app} #{run}: window {info['window_ms']} ms, shell {info['child_ms']} ms, display {window.get('display')}")
            time.sleep(1)
            kill(int(info["pid"]))
    f.close()


def phase_throughput(out, grid, runs):
    """Seconds for `cat` to push each data file through the terminal."""
    subprocess.run([sys.executable, os.path.join(BENCH, "gen-data.py"), DATA, str(grid[0]), str(grid[1])], check=True)
    runner = os.path.join(BENCH, "runner.sh")
    pids = {}
    info = launch_plum()
    pids["plum"] = int(info["pid"])
    time.sleep(2.5)
    plum(f"type sh {runner} {WORK} plum\\n")
    info = launch_ghostty(grid, command=["/bin/sh", runner, WORK, "ghostty"])
    pids["ghostty"] = int(info["pid"])
    for app in pids:
        if not wait_for(os.path.join(WORK, f"ready-{app}"), 15):
            raise RuntimeError(f"{app}: runner did not start")
    with open(os.path.join(out, "throughput_windows.txt"), "w") as windows:
        for app, pid in pids.items():
            windows.write(f"{app}: {require_visible(app, pid)}\n")

    f, w = writer(out, "throughput", ["dataset", "app", "run", "seconds", "mb_per_s", "valid", "load1"])
    for dataset in DATASETS:
        path = os.path.join(DATA, dataset + ".txt")
        size_mb = os.path.getsize(path) / 1e6
        for run in range(runs + 1):  # run 0 is a warm-up
            for app in (("plum", "ghostty") if run % 2 else ("ghostty", "plum")):
                before = visible(pids[app]) is not None
                time.sleep(0.3)
                result = os.path.join(WORK, f"result-{app}")
                if os.path.exists(result):
                    os.remove(result)
                with open(os.path.join(WORK, f"go-{app}.tmp"), "w") as go:
                    go.write(path)
                os.rename(os.path.join(WORK, f"go-{app}.tmp"), os.path.join(WORK, f"go-{app}"))
                if not wait_for(result, 180):
                    raise RuntimeError(f"{app}: {dataset} did not finish")
                seconds = float(open(result).read())
                after = visible(pids[app]) is not None
                w.writerow([dataset, app, run, f"{seconds:.4f}", f"{size_mb / seconds:.1f}",
                            "yes" if before and after else "no", f"{load():.1f}"])
                f.flush()
                print(f"{dataset} {app} #{run}: {seconds:.3f} s ({size_mb / seconds:.0f} MB/s)")
    f.close()

    # Memory once the scrollback is full, which is where a long session ends up.
    f, w = writer(out, "memory_after_output", ["app", "footprint_mb", "peak_mb"])
    time.sleep(5)
    for app, pid in pids.items():
        require_visible(app, pid)
        time.sleep(4)
        usage = fields(tool("sample", pid))
        w.writerow([app, usage["footprint_mb"], usage["peak_mb"]])
    f.close()
    for app, pid in pids.items():
        with open(os.path.join(WORK, f"go-{app}"), "w") as go:
            go.write("quit")
        time.sleep(0.3)
        kill(pid)


def phase_latency(out, grid, blocks, per_block, pause_ms=None, name="latency"):
    """Key press to the frame that shows it, with the tty echoing each key.
    With `pause_ms`, every key follows that much idle time."""
    pids = {}
    info = launch_plum()
    pids["plum"] = int(info["pid"])
    time.sleep(2.5)
    plum("type clear; exec cat > /dev/null\\n")
    info = launch_ghostty(grid, extra=["--cursor-style-blink=false"], command=["/bin/sh", "-c", "clear; exec cat > /dev/null"])
    pids["ghostty"] = int(info["pid"])
    time.sleep(2.5)

    with open(os.path.join(out, name + "_windows.txt"), "w") as f:
        for app, pid in pids.items():
            f.write(f"{app}: {require_visible(app, pid)}\n")

    f, w = writer(out, name, ["app", "block", "sample", "latency_ms", "arrival_ms"])
    for block in range(blocks):
        for app in (("plum", "ghostty") if block % 2 else ("ghostty", "plum")):
            target = os.path.join(WORK, f"latency-{app}.csv")
            extra = [pause_ms] if pause_ms else []
            print(f"{name} {app} block {block}: {tool('latency', pids[app], per_block, target, *extra, check=False)}")
            if not os.path.exists(target):
                continue
            with open(target) as rows:
                for row in list(csv.reader(rows))[1:]:
                    w.writerow([app, block, *row])
            os.remove(target)
            f.flush()
    f.close()
    for pid in pids.values():
        kill(pid)


def phase_memory(out, grid, runs):
    """Footprint of one visible terminal left alone for a minute, and the CPU
    it uses over the last 30 seconds of that minute."""
    variants = {
        "plum": lambda: launch_plum(debug=False),
        "ghostty": lambda: launch_ghostty(grid),
        "ghostty-noblink": lambda: launch_ghostty(grid, extra=["--cursor-style-blink=false"]),
    }
    f, w = writer(out, "memory", ["variant", "run", "fp_5s_mb", "fp_10s_mb", "fp_20s_mb", "fp_30s_mb", "fp_60s_mb", "peak_mb",
                                  "idle_cpu_ms_per_30s", "valid", "load1"])
    for run in range(runs):
        order = list(variants)
        order = order[run % 3:] + order[:run % 3]
        for variant in order:
            if variant == "ghostty-noblink" and run >= max(1, runs // 2):
                continue  # a side question; half the runs are enough
            pid = int(variants[variant]()["pid"])
            start = time.time()
            shown = True
            try:
                require_visible(variant, pid)
            except RuntimeError:
                shown = False
            samples = {}
            for at in (5, 10, 20, 30, 60):
                time.sleep(max(0, start + at - time.time()))
                samples[at] = fields(tool("sample", pid))
            still = shown and visible(pid) is not None
            w.writerow([variant, run, *(samples[at]["footprint_mb"] for at in (5, 10, 20, 30, 60)), samples[60]["peak_mb"],
                        f"{float(samples[60]['cpu_ms']) - float(samples[30]['cpu_ms']):.1f}",
                        "yes" if still else "no", f"{load():.1f}"])
            f.flush()
            print(f"memory {variant} #{run}: {samples[60]['footprint_mb']} MB at 60 s, "
                  f"{float(samples[60]['cpu_ms']) - float(samples[30]['cpu_ms']):.0f} ms CPU in 30 s idle")
            kill(pid)
    f.close()


def phase_tabs(out, grid, runs):
    """Footprint with ten terminals open in one window."""
    f, w = writer(out, "tabs", ["app", "run", "terminals", "fp_1_mb", "fp_10_mb", "peak_mb", "load1"])
    for run in range(runs):
        for app in (("plum", "ghostty") if run % 2 else ("ghostty", "plum")):
            info = launch_plum() if app == "plum" else launch_ghostty(grid)
            pid = int(info["pid"])
            require_visible(app, pid)
            time.sleep(8)
            one = fields(tool("sample", pid))

            def terminals():
                # Each Ghostty tab is one child process (its login shell).
                return len(json.loads(plum("state"))["tabs"]) if app == "plum" else int(tool("children", pid))

            attempts = 0
            while terminals() < 10 and attempts < 25:  # a keystroke is sometimes lost while focus settles
                tool("key", pid, 17, "cmd", check=False)  # ⌘T
                time.sleep(0.8)
                attempts += 1
            time.sleep(15)
            terminals = terminals()
            ten = fields(tool("sample", pid))
            w.writerow([app, run, terminals, one["footprint_mb"], ten["footprint_mb"], ten["peak_mb"], f"{load():.1f}"])
            f.flush()
            print(f"tabs {app} #{run}: {terminals} terminals, {one['footprint_mb']} → {ten['footprint_mb']} MB")
            kill(pid)
    f.close()


def phase_idle(out, grid, runs):
    """Plum only: what it does while left alone, with its own counters, to
    tell terminal activity (bytes in, frames drawn) from everything else."""
    f, w = writer(out, "plum_idle", ["run", "cpu_ms_per_30s", "frames_drawn", "bytes_received", "fp_30s_mb", "fp_60s_mb", "valid", "load1"])
    for run in range(runs):
        pid = int(launch_plum()["pid"])
        start = time.time()
        require_visible("plum", pid)
        time.sleep(max(0, start + 30 - time.time()))
        usage_a, stats_a = fields(tool("sample", pid)), fields(plum("stats"))
        time.sleep(max(0, start + 60 - time.time()))
        usage_b, stats_b = fields(tool("sample", pid)), fields(plum("stats"))
        still = visible(pid) is not None
        w.writerow([run, f"{float(usage_b['cpu_ms']) - float(usage_a['cpu_ms']):.1f}",
                    int(stats_b["frames"]) - int(stats_a["frames"]), int(stats_b["bytes"]) - int(stats_a["bytes"]),
                    usage_a["footprint_mb"], usage_b["footprint_mb"], "yes" if still else "no", f"{load():.1f}"])
        f.flush()
        print(f"idle plum #{run}: {float(usage_b['cpu_ms']) - float(usage_a['cpu_ms']):.0f} ms CPU, "
              f"{int(stats_b['frames']) - int(stats_a['frames'])} frames, {int(stats_b['bytes']) - int(stats_a['bytes'])} bytes")
        kill(pid)
    f.close()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    quick = "--quick" in sys.argv
    out = os.path.join(BENCH, "results", time.strftime("%Y%m%d-%H%M"))
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
        args = [a for a in args if a != out]
    phases = ["launch", "throughput", "latency", "memory", "tabs"] if args in ([], ["all"]) else args
    os.makedirs(out, exist_ok=True)

    prepare_work()
    try:
        grid = plum_grid()
        with open(os.path.join(out, "env.txt"), "a") as f:
            f.write(f"date: {time.strftime('%Y-%m-%d %H:%M:%S')}\nphases: {' '.join(phases)}\ngrid: {grid[0]}x{grid[1]}\n")
            f.write(f"load at start: {os.getloadavg()}\n")
            f.write(f"display: id {home['display']}, scale {home['scale']}x, {home['refresh']} Hz\n")
            for command in (["sw_vers"], ["sysctl", "-n", "machdep.cpu.brand_string"],
                            [os.path.join(GHOSTTY, "Contents/MacOS/ghostty"), "+version"]):
                f.write(subprocess.run(command, capture_output=True, text=True).stdout.strip() + "\n")
        for phase in phases:
            print(f"== {phase}")
            if phase == "launch":
                phase_launch(out, grid, 3 if quick else 15)
            elif phase == "throughput":
                phase_throughput(out, grid, 2 if quick else 10)
            elif phase == "latency":
                phase_latency(out, grid, 2 if quick else 8, 10 if quick else 50)
            elif phase == "latency_idle":
                phase_latency(out, grid, 2 if quick else 4, 3 if quick else 12, pause_ms=5000, name="latency_idle")
            elif phase == "memory":
                phase_memory(out, grid, 1 if quick else 4)
            elif phase == "tabs":
                phase_tabs(out, grid, 1 if quick else 5)
            elif phase == "idle":
                phase_idle(out, grid, 1 if quick else 6)
            else:
                raise SystemExit(f"unknown phase {phase}")
    finally:
        cleanup()
    print(f"results: {out}")


if __name__ == "__main__":
    main()
