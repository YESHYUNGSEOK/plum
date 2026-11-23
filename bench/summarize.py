#!/usr/bin/env python3
"""Turns a results folder from run.py into a Markdown report.

usage: summarize.py <results dir>

Reports the median with the quartiles and range next to it, and how many
samples went in. Warm-up runs (run 0) and samples taken while the app was
not frontmost and on screen are left out and counted as such.
"""
import csv
import os
import statistics
import sys

folder = sys.argv[1]


def rows(name):
    path = os.path.join(folder, name + ".csv")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def describe(values, digits=1):
    """median [Q1–Q3] (min–max), n"""
    if not values:
        return "—"
    values = sorted(values)
    if len(values) >= 4:
        quartiles = statistics.quantiles(values, n=4, method="inclusive")
        spread = f"[{quartiles[0]:.{digits}f}–{quartiles[2]:.{digits}f}] "
    else:
        spread = ""
    return f"**{statistics.median(values):.{digits}f}** {spread}({values[0]:.{digits}f}–{values[-1]:.{digits}f}), n={len(values)}"


def ratio(a, b):
    """How many times larger the median of `a` is than the median of `b`."""
    if not a or not b:
        return "—"
    return f"{statistics.median(a) / statistics.median(b):.2f}×"


NAMES = {"plum": "Plum", "ghostty": "Ghostty", "orca": "Orca"}


def apps_in(table):
    return [app for app in NAMES if any(r["app"] == app for r in table)]


out = []
env = os.path.join(folder, "env.txt")
if os.path.exists(env):
    out += ["## Environment", "", "```", open(env).read().strip(), "```", ""]

out += ["Values are the **median** [Q1–Q3] (min–max), n = number of samples.", ""]

launch = [r for r in rows("launch") if r["run"] != "0"]
if launch:
    dropped = sum(1 for r in launch if r["valid"] != "yes")
    launch = [r for r in launch if r["valid"] == "yes"]
    apps = apps_in(launch)
    out += ["## Launch time (ms)", "", "| Interval | " + " | ".join(NAMES[a] for a in apps) + " |", "|---|" + "---|" * len(apps)]
    for key, label in (("window_ms", "Launch request → window on screen"), ("child_ms", "Launch request → shell process started")):
        cells = [describe([float(r[key]) for r in launch if r["app"] == a and r[key]], 0) for a in apps]
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    out += ["", f"Samples left out: {dropped} (window not on screen).", ""]

throughput = [r for r in rows("throughput") if r["run"] != "0"]
if throughput:
    dropped = sum(1 for r in throughput if r["valid"] != "yes")
    throughput = [r for r in throughput if r["valid"] == "yes"]
    apps = apps_in(throughput)
    others = [a for a in apps if a != "plum"]
    out += ["## Output throughput (MB/s, higher is faster)", "",
            "| Data | " + " | ".join(NAMES[a] for a in apps) + " | " + " | ".join(f"Plum ÷ {NAMES[a]}" for a in others) + " |",
            "|---|" + "---|" * (len(apps) + len(others))]
    for dataset in dict.fromkeys(r["dataset"] for r in throughput):
        speed = {a: [float(r["mb_per_s"]) for r in throughput if r["dataset"] == dataset and r["app"] == a] for a in apps}
        out.append(f"| {dataset} | " + " | ".join(describe(speed[a], 0) for a in apps) + " | "
                   + " | ".join(ratio(speed["plum"], speed[a]) for a in others) + " |")
    out += ["", f"Samples left out: {dropped} (another app was in front during the run).", ""]

for name, title in (("latency", "Key press → on screen latency, continuous typing (ms, lower is faster)"),
                    ("latency_idle", "Key press → on screen latency, first key after 5 s idle (ms)")):
    latency = rows(name)
    if not latency:
        continue
    apps = apps_in(latency)
    out += [f"## {title}", "", "| | " + " | ".join(NAMES[a] for a in apps) + " |", "|---|" + "---|" * len(apps)]
    values = {app: sorted(float(r["latency_ms"]) for r in latency if r["app"] == app) for app in apps}
    out.append("| Median [quartiles] (range) | " + " | ".join(describe(values[a]) for a in apps) + " |")
    for label, pick in (("Mean", statistics.mean), ("95th percentile", lambda v: v[int(len(v) * 0.95) - 1])):
        out.append(f"| {label} | " + " | ".join(f"{pick(values[a]):.1f}" if values[a] else "—" for a in apps) + " |")
    out.append("")
    # Per block, to show whether the difference holds each time or only on average.
    blocks = sorted({int(r["block"]) for r in latency})
    out += ["Median per block (the apps measured in turn):", "", "| Block | " + " | ".join(str(b) for b in blocks) + " |",
            "|---|" + "---|" * len(blocks)]
    for app in apps:
        cells = []
        for block in blocks:
            v = [float(r["latency_ms"]) for r in latency if r["app"] == app and int(r["block"]) == block]
            cells.append(f"{statistics.median(v):.1f}" if v else "—")
        out.append(f"| {app} | " + " | ".join(cells) + " |")
    out.append("")

memory = rows("memory")
if memory:
    dropped = sum(1 for r in memory if r["valid"] != "yes")
    memory = [r for r in memory if r["valid"] == "yes"]
    variants = list(dict.fromkeys(r["variant"] for r in memory))
    out += ["## Memory and idle CPU (1 terminal, on screen)", "",
            "| Measure | " + " | ".join(variants) + " |", "|---|" + "---|" * len(variants)]
    for key, label, digits in (("fp_10s_mb", "Memory 10 s after launch (MB)", 1), ("fp_60s_mb", "Memory 60 s after launch (MB)", 1),
                               ("peak_mb", "Peak memory (MB)", 1), ("idle_cpu_ms_per_30s", "CPU used in 30 s idle (ms)", 0)):
        cells = [describe([float(r[key]) for r in memory if r["variant"] == v], digits) for v in variants]
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    out += ["", f"Samples left out: {dropped}.", ""]

tabs = rows("tabs")
if tabs:
    apps = apps_in(tabs)
    out += ["## 10 terminals", "", "| Measure | " + " | ".join(NAMES[a] for a in apps) + " |", "|---|" + "---|" * len(apps)]
    for key, label in (("fp_1_mb", "With 1 terminal (MB)"), ("fp_10_mb", "With 10 terminals (MB)")):
        cells = [describe([float(r[key]) for r in tabs if r["app"] == app and r["terminals"] == "10"]) for app in apps]
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    wrong = [f"{r['app']} with {r['terminals']}" for r in tabs if r["terminals"] != "10"]
    out += ["", "Runs without 10 terminals (left out): " + (", ".join(wrong) if wrong else "none") + ".", ""]

after = rows("memory_after_output")
if after:
    out += ["## Memory after heavy output (scrollback full, 1 run)", "", "| App | Memory (MB) | Peak (MB) |", "|---|---|---|"]
    out += [f"| {r['app']} | {r['footprint_mb']} | {r['peak_mb']} |" for r in after]
    out.append("")

print("\n".join(out))
