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


out = []
env = os.path.join(folder, "env.txt")
if os.path.exists(env):
    out += ["## 측정 환경", "", "```", open(env).read().strip(), "```", ""]

out += ["표의 값은 **중앙값** [1사분위–3사분위] (최소–최대), n=표본 수 형식이다.", ""]

launch = [r for r in rows("launch") if r["run"] != "0"]
if launch:
    dropped = sum(1 for r in launch if r["valid"] != "yes")
    launch = [r for r in launch if r["valid"] == "yes"]
    out += ["## 실행 시간 (ms)", "", "| 구간 | Plum | Ghostty | Ghostty ÷ Plum |", "|---|---|---|---|"]
    for key, label in (("window_ms", "실행 요청 → 창이 화면에 뜸"), ("child_ms", "실행 요청 → 셸 프로세스 시작")):
        plum = [float(r[key]) for r in launch if r["app"] == "plum"]
        ghostty = [float(r[key]) for r in launch if r["app"] == "ghostty"]
        out.append(f"| {label} | {describe(plum, 0)} | {describe(ghostty, 0)} | {ratio(ghostty, plum)} |")
    out += ["", f"제외한 표본: {dropped}개 (창이 화면에 보이지 않음).", ""]

throughput = [r for r in rows("throughput") if r["run"] != "0"]
if throughput:
    dropped = sum(1 for r in throughput if r["valid"] != "yes")
    throughput = [r for r in throughput if r["valid"] == "yes"]
    out += ["## 출력 처리 속도 (MB/s, 클수록 빠름)", "", "| 데이터 | Plum | Ghostty | Plum ÷ Ghostty |", "|---|---|---|---|"]
    for dataset in dict.fromkeys(r["dataset"] for r in throughput):
        plum = [float(r["mb_per_s"]) for r in throughput if r["dataset"] == dataset and r["app"] == "plum"]
        ghostty = [float(r["mb_per_s"]) for r in throughput if r["dataset"] == dataset and r["app"] == "ghostty"]
        out.append(f"| {dataset} | {describe(plum, 0)} | {describe(ghostty, 0)} | {ratio(plum, ghostty)} |")
    out += ["", f"제외한 표본: {dropped}개 (측정 중 다른 앱이 앞에 있었음).", ""]

for name, title in (("latency", "키 입력 → 화면 표시 지연, 연속 입력 (ms, 작을수록 빠름)"),
                    ("latency_idle", "키 입력 → 화면 표시 지연, 5초 쉬고 난 첫 키 (ms)")):
    latency = rows(name)
    if not latency:
        continue
    out += [f"## {title}", "",
            "| | Plum | Ghostty |", "|---|---|---|"]
    values = {app: sorted(float(r["latency_ms"]) for r in latency if r["app"] == app) for app in ("plum", "ghostty")}
    out.append(f"| 중앙값 [사분위] (범위) | {describe(values['plum'])} | {describe(values['ghostty'])} |")
    for label, pick in (("평균", statistics.mean), ("95번째 백분위", lambda v: v[int(len(v) * 0.95) - 1])):
        cells = [f"{pick(values[app]):.1f}" if values[app] else "—" for app in ("plum", "ghostty")]
        out.append(f"| {label} | {cells[0]} | {cells[1]} |")
    out.append("")
    # Per block, to show whether the difference holds each time or only on average.
    blocks = sorted({int(r["block"]) for r in latency})
    out += ["블록별 중앙값 (두 앱을 번갈아 측정):", "", "| 블록 | " + " | ".join(str(b) for b in blocks) + " |",
            "|---|" + "---|" * len(blocks)]
    for app in ("plum", "ghostty"):
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
    out += ["## 메모리와 유휴 CPU (터미널 1개, 화면에 보이는 상태)", "",
            "| 항목 | " + " | ".join(variants) + " |", "|---|" + "---|" * len(variants)]
    for key, label, digits in (("fp_10s_mb", "실행 10초 뒤 메모리 (MB)", 1), ("fp_60s_mb", "실행 60초 뒤 메모리 (MB)", 1),
                               ("peak_mb", "최대 메모리 (MB)", 1), ("idle_cpu_ms_per_30s", "유휴 30초 동안 쓴 CPU (ms)", 0)):
        cells = [describe([float(r[key]) for r in memory if r["variant"] == v], digits) for v in variants]
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    out += ["", f"제외한 표본: {dropped}개.", ""]

tabs = rows("tabs")
if tabs:
    out += ["## 터미널 10개", "", "| 항목 | Plum | Ghostty |", "|---|---|---|"]
    for key, label in (("fp_1_mb", "터미널 1개일 때 (MB)"), ("fp_10_mb", "터미널 10개일 때 (MB)")):
        cells = [describe([float(r[key]) for r in tabs if r["app"] == app and r["terminals"] == "10"]) for app in ("plum", "ghostty")]
        out.append(f"| {label} | {cells[0]} | {cells[1]} |")
    wrong = [f"{r['app']} {r['terminals']}개" for r in tabs if r["terminals"] != "10"]
    out += ["", "터미널이 10개가 아니었던 실행(제외): " + (", ".join(wrong) if wrong else "없음") + ".", ""]

after = rows("memory_after_output")
if after:
    out += ["## 대량 출력 뒤 메모리 (스크롤백이 찬 상태, 1회)", "", "| 앱 | 메모리 (MB) | 최대 (MB) |", "|---|---|---|"]
    out += [f"| {r['app']} | {r['footprint_mb']} | {r['peak_mb']} |" for r in after]
    out.append("")

print("\n".join(out))
