#!/usr/bin/env python3
"""How much of each terminal's output speed goes to drawing?

usage: drawing-cost.py <out.csv>

Runs the throughput data through Plum and Ghostty twice: with the window
frontmost (drawing) and minimized (not drawing). If an app is much faster
minimized, drawing is what holds it back.
"""
import csv
import os
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

DATASETS = ["ascii", "dense_cells", "unicode", "cursor_motion", "sync_tui"]
RUNS = 4


def measure(app, pid, path):
    result = os.path.join(run.WORK, f"result-{app}")
    if os.path.exists(result):
        os.remove(result)
    with open(os.path.join(run.WORK, f"go-{app}.tmp"), "w") as go:
        go.write(path)
    os.rename(os.path.join(run.WORK, f"go-{app}.tmp"), os.path.join(run.WORK, f"go-{app}"))
    if not run.wait_for(result, 180):
        raise RuntimeError(f"{app}: did not finish")
    return float(open(result).read())


def main():
    out = sys.argv[1]
    run.prepare_work()
    rows = []
    try:
        grid = run.plum_grid()
        subprocess.run([sys.executable, os.path.join(run.BENCH, "gen-data.py"), run.DATA, str(grid[0]), str(grid[1])],
                       check=True, capture_output=True)
        runner = os.path.join(run.BENCH, "runner.sh")
        for app in ("plum", "ghostty"):
            if app == "plum":
                pid = int(run.launch_plum()["pid"])
                time.sleep(2.5)
                run.plum(f"type sh {runner} {run.WORK} plum\\n")
            else:
                pid = int(run.launch_ghostty(grid, command=["/bin/sh", runner, run.WORK, "ghostty"])["pid"])
            if not run.wait_for(os.path.join(run.WORK, f"ready-{app}"), 15):
                raise RuntimeError(f"{app}: runner did not start")
            for state in ("drawing", "minimized"):
                if state == "drawing":
                    run.require_visible(app, pid)
                else:
                    run.tool("minimize", pid, 1)
                    time.sleep(2)
                    window = run.tool("window", pid, check=False)
                    if "onscreen=yes" in window:
                        raise RuntimeError(f"{app}: still on screen after minimizing")
                for dataset in DATASETS:
                    path = os.path.join(run.DATA, dataset + ".txt")
                    size = os.path.getsize(path) / 1e6
                    for index in range(RUNS + 1):  # the first is a warm-up
                        if state == "drawing" and run.visible(pid) is None:
                            continue
                        seconds = measure(app, pid, path)
                        if index:
                            rows.append([app, state, dataset, f"{size / seconds:.1f}"])
                    values = [float(r[3]) for r in rows if r[:3] == [app, state, dataset]]
                    print(f"{app:8s} {state:10s} {dataset:14s} {statistics.median(values):6.0f} MB/s  (n={len(values)})", flush=True)
            run.kill(pid)
    finally:
        run.cleanup()
        with open(out, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["app", "state", "dataset", "mb_per_s"])
            writer.writerows(rows)


if __name__ == "__main__":
    main()
