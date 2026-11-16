#!/usr/bin/env python3
"""Generates the terminal output used by the throughput benchmark.

usage: gen-data.py <out dir> <cols> <rows>

The cases follow the categories of alacritty/vtebench (plain scrolling,
dense styled cells, cursor motion, scroll regions, unicode) plus one that
mimics an agent TUI repainting inside synchronized-output brackets.
Output is deterministic: the same arguments always give the same bytes.
"""
import os
import random
import sys

out, cols, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(out, exist_ok=True)
rng = random.Random(20261116)
ESC = "\x1b"


def write(name, chunks, size):
    """Repeats `chunks` (a generator of str) until `size` bytes are written."""
    path = os.path.join(out, name + ".txt")
    written = 0
    with open(path, "wb") as f:
        while written < size:
            for chunk in chunks():
                data = chunk.encode()
                f.write(data)
                written += len(data)
                if written >= size:
                    break
        f.write(f"{ESC}[0m{ESC}[r{ESC}[?2026l\r\n".encode())  # leave the terminal sane
    print(f"{name:14s} {written / 1e6:7.1f} MB")


ASCII = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def ascii_lines():
    for _ in range(5000):
        yield "".join(rng.choice(ASCII) for _ in range(76)) + "\r\n"


def scrolling():
    yield "y\r\n" * 20000


def dense_cells():
    # Every cell gets its own colors and attributes, the worst case for style handling.
    frame = [f"{ESC}[H"]
    for row in range(rows):
        for _ in range(cols):
            frame.append(
                f"{ESC}[{rng.choice('01347')};38;5;{rng.randrange(256)};48;5;{rng.randrange(256)}m"
                f"{rng.choice(ASCII)}")
        if row != rows - 1:
            frame.append("\r\n")
    yield "".join(frame)


UNICODE_RANGES = [(0xAC00, 0xD7A3), (0x4E00, 0x9FFF), (0x2500, 0x257F), (0x2190, 0x21FF), (0x0400, 0x04FF), (0x1F600, 0x1F64F)]


def unicode_lines():
    for _ in range(2000):
        line = []
        width = 0
        while width < cols - 2:
            lo, hi = rng.choice(UNICODE_RANGES)
            line.append(chr(rng.randrange(lo, hi + 1)))
            width += 2 if lo >= 0x1100 and lo not in (0x2500, 0x2190) else 1
        yield "".join(line) + "\r\n"


def cursor_motion():
    yield "".join(
        f"{ESC}[{rng.randrange(1, rows + 1)};{rng.randrange(1, cols + 1)}H{rng.choice(ASCII)}" for _ in range(20000))


def scroll_region():
    yield f"{ESC}[5;{rows - 5}r{ESC}[5;1H" + "y\r\n" * 20000


SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
WORDS = ["Reading", "src/main.swift", "편집 중", "Running tests", "✓ 12 passed", "Thinking…", "git diff", "빌드 완료"]


def sync_tui():
    # A 12-line status block redrawn in place, the way an agent's TUI updates:
    # hold rendering, move up, rewrite each line, release.
    height = 12
    yield "\r\n" * height
    for tick in range(4000):
        frame = [f"{ESC}[?2026h{ESC}[{height}A"]
        for line in range(height):
            color = 31 + (tick + line) % 6
            frame.append(
                f"{ESC}[2K{ESC}[1;{color}m{SPINNER[(tick + line) % len(SPINNER)]}{ESC}[0m "
                f"{rng.choice(WORDS)} {ESC}[2m{tick * 7 + line}{ESC}[0m {rng.choice(WORDS)}\r\n")
        frame.append(f"{ESC}[?2026l")
        yield "".join(frame)


write("ascii", ascii_lines, 100_000_000)
write("scrolling", scrolling, 20_000_000)
write("dense_cells", dense_cells, 50_000_000)
write("unicode", unicode_lines, 30_000_000)
write("cursor_motion", cursor_motion, 30_000_000)
write("scroll_region", scroll_region, 20_000_000)
write("sync_tui", sync_tui, 20_000_000)
