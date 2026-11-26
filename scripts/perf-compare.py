#!/usr/bin/env python3
"""Compares two checkouts of Plum for speed and memory, and fails when the
second is worse than the first by more than a limit.

usage: perf-compare.py <base checkout> <head checkout> [--rounds N] [--limit PERCENT]

Measured, by tests that are skipped in an ordinary `swift test`:
  - parsing speed per kind of output (PtySpeedTests.testParseSpeed), in MB per
    second of CPU time, so a busy machine changes it little;
  - memory per terminal, new and after output (SessionMemoryTests).
The two checkouts take turns, so a machine that slows down partway slows both.
Each needs Vendor/GhosttyVt.xcframework (scripts/build-vt.sh).

Not measured here: key latency, drawing and launch time. They need a real
display and are measured by hand before releases (docs/benchmarks/).
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import tempfile

FLAGS = ["-c", "release", "-Xswiftc", "-enable-testing"]
TESTS = "PtySpeedTests/testParseSpeed|SessionMemoryTests"


def measure(checkout, data):
    out = subprocess.run(
        ["swift", "test", "--package-path", checkout, *FLAGS, "--skip-build", "--filter", TESTS],
        env={**os.environ, "PLUM_BENCH_DATA": data}, capture_output=True, text=True)
    text = out.stdout + out.stderr
    if out.returncode != 0:
        sys.exit(f"measuring {checkout} failed:\n{text[-3000:]}")
    found = {}
    for name, speed in re.findall(r"^PARSE (\S+)\s+median (\d+) MB/s", text, re.M):
        found[f"parse {name} (MB/s)"] = float(speed)
    memory = re.search(r"^MEM .*new ([\d.]+) MB each, after .*? each ([\d.]+) MB each", text, re.M)
    if memory:
        found["memory, new terminal (MB)"] = float(memory.group(1))
        found["memory, after output (MB)"] = float(memory.group(2))
    if len(found) < 3:
        sys.exit(f"no measurements in the output of {checkout}:\n{text[-3000:]}")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("head")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--limit", type=float, default=10, help="percent worse that fails")
    args = parser.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))

    with tempfile.TemporaryDirectory() as data:
        subprocess.run([sys.executable, os.path.join(here, "..", "bench", "gen-data.py"), data, "122", "46"],
                       check=True, stdout=subprocess.DEVNULL)
        for checkout in (args.base, args.head):
            subprocess.run(["swift", "build", "--package-path", checkout, *FLAGS, "--build-tests"], check=True)
        runs = {"base": [], "head": []}
        for _ in range(args.rounds):
            runs["base"].append(measure(args.base, data))
            runs["head"].append(measure(args.head, data))

    lines = ["| | base | this change | change | |", "|---|---|---|---|---|"]
    worse = []
    for name in runs["base"][0]:
        if any(name not in run for side in runs.values() for run in side):
            continue  # measured on one side only: the change added or renamed it
        base = statistics.median(run[name] for run in runs["base"])
        head = statistics.median(run[name] for run in runs["head"])
        change = (head / base - 1) * 100 if base else 0
        # More MB/s is better; more MB is worse.
        loss = -change if name.startswith("parse") else change
        # A terminal's memory in MB is small: under 0.2 MB of difference is noise, whatever the percentage.
        failed = loss > args.limit and (name.startswith("parse") or abs(head - base) >= 0.2)
        if failed:
            worse.append(name)
        lines.append(f"| {name} | {base:g} | {head:g} | {change:+.1f}% | {'**worse**' if failed else ''} |")
    verdict = (f"Worse by more than {args.limit:g}%: {', '.join(worse)}." if worse
               else f"Nothing is worse by more than {args.limit:g}%.")
    report = "\n".join(["### Performance compared with the base", "", *lines, "", verdict,
                        "", f"Medians of {args.rounds} rounds each, taking turns. Latency, drawing and launch time are not measured here."])
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report + "\n")
    sys.exit(1 if worse else 0)


main()
