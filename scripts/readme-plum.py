#!/usr/bin/env python3
"""Draws docs/assets/plum.svg, the README's header: an ASCII plum turning
on a tilted axis in a terminal window.

    uv run --with numpy --with pillow scripts/readme-plum.py [preview.png]

The plum (body with its seam and hollow, stem, leaf) is ray-marched as
signed distance fields, every cell sampled 4x8 times. Each cell gets the
Menlo glyph whose ink best matches its samples, so edges pick '/', '(', '_'
and the like rather than only a brightness ramp. The frames are stacked in
one strip that a CSS steps() animation slides through; with Reduce Motion
the first frame stays.
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 72, 32
FRAMES, SECONDS = 90, 7.5
SX, SY = 4, 8                       # samples per cell
CW, LH = 8, 16                      # cell size in the SVG, px
PAD_X, PAD_Y, BAR = 28, 12, 34      # window padding and title bar, px
FONT = "/System/Library/Fonts/Menlo.ttc"
EM = CW / (1233 / 2048)             # the font size that gives Menlo an 8 px advance
BASE = 12.6                         # baseline below a cell's top, px
RAMP = " .'`,-:;~=+*!ilrcvxzsoaenuLJTYCOQ0ZUXmwpqdbkhKAMW#B8%&@"
EDGE = " ()/\\|_-.,'`<>[]:;~^"
FLOOR = ".,::;"
CHARS = "".join(dict.fromkeys(RAMP + EDGE))
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs/assets/plum.svg"
SWIFT_OUT = ROOT / "scripts/icon/AsciiPlumFrames.swift"   # the small one, for the app icon

BACK, BAR_FILL, LINE, TITLE = "#141417", "#1E1E22", "#2C2C32", "#8E8E99"
RAMPS = {  # dark to light; the last skin color is the highlight
    1: ["#3A1D5E", "#4E2683", "#6630A6", "#8143C6", "#9F5FE4", "#C58AF9", "#E4C8FF", "#F7EEFF"],
    2: ["#4F3624", "#73513A", "#9A7552"],
    3: ["#1E4A2C", "#2A673C", "#3B8C50", "#58B26B", "#8ED79C"],
    4: ["#2A2431", "#3A3144"],
}


def norm(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def capsule(p, a, b, r):
    pa, ba = p - a, b - a
    h = np.clip(pa @ ba / (ba @ ba), 0, 1)
    return np.linalg.norm(pa - h[:, None] * ba, axis=1) - r


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)


# The plum, in its own coordinates: y up, the seam on the +z side.
RADII = np.array([1.0, 1.05, 0.92])
S0, S1, S2 = np.array([0, 0.76, 0]), np.array([0.03, 1.07, 0.01]), np.array([0.14, 1.31, 0.05])
LEAF_A = np.array([0.08, 1.02, 0.03])
LEAF_U = norm([1, 0.12, 0.25])
_n = norm([-0.12, 1, 0.2])
LEAF_N = norm(_n - (_n @ LEAF_U) * LEAF_U)
LEAF_V = np.cross(LEAF_N, LEAF_U)
LEAF_L, LEAF_W = 1.25, 0.42
_PEAK = 0.4**0.6 * 0.6**0.9


def parts(q):
    x, y, z = q[:, 0], q[:, 1], q[:, 2]
    k0 = np.linalg.norm(q / RADII, axis=1)
    k1 = np.linalg.norm(q / RADII**2, axis=1)
    body = k0 * (k0 - 1) / np.maximum(k1, 1e-9)
    body = body + SEAM_DEPTH * np.exp(-((x / SEAM_WIDTH) ** 2)) * smoothstep(-0.2, 0.5, z)    # seam
    body = body + 0.2 * np.exp(-(x * x + z * z) / 0.05) * smoothstep(0.45, 1.0, y)  # hollow
    stem = np.minimum(capsule(q, S0, S1, 0.05), capsule(q, S1, S2, 0.042))
    d = q - LEAF_A
    lu, lv, lh = d @ LEAF_U, d @ LEAF_V, d @ LEAF_N
    t = np.clip(lu / LEAF_L, 0, 1)
    half = LEAF_W * t**0.6 * (1 - t) ** 0.9 / _PEAK
    curve = 0.22 * np.abs(lv) - 0.3 * LEAF_L * t * t         # folded at the midrib, tip drooping
    outside = np.maximum(np.abs(lv) - half, np.maximum(-lu, lu - LEAF_L))
    blade = np.maximum(np.abs(lh - curve) - 0.014, outside) * 0.6
    leaf = np.minimum(blade, capsule(q, np.array([0.02, 0.95, 0.01]), LEAF_A, 0.02))
    return body, stem, leaf, lu, lv


PITCH, ROLL = 0.22, -0.2            # the axis leans toward the viewer and to the right
CENTER = np.array([0.0, 0.08, 0.0])
GROUND = -1.2
SHADOW = True
SEAM_DEPTH, SEAM_WIDTH, SEAM_DARK, SEAM_LINE = 0.09, 0.14, 0.55, 0.06   # the groove, and the dark line in it
EYE, LOOK = np.array([0, 1.9, 7.4]), np.array([0, 0.05, 0])
VIEW_H = 3.45                        # world height of the grid at LOOK
L_KEY, L_FILL = norm([-0.55, 0.8, 0.55]), norm([0.9, 0.1, 0.35])


def rotation(theta):
    c, s = math.cos, math.sin
    ry = np.array([[c(theta), 0, s(theta)], [0, 1, 0], [-s(theta), 0, c(theta)]])
    rx = np.array([[1, 0, 0], [0, c(PITCH), -s(PITCH)], [0, s(PITCH), c(PITCH)]])
    rz = np.array([[c(ROLL), -s(ROLL), 0], [s(ROLL), c(ROLL), 0], [0, 0, 1]])
    return rz @ rx @ ry


def rays():
    fwd = norm(LOOK - EYE)
    right = norm(np.cross(fwd, [0, 1, 0]))
    up = np.cross(right, fwd)
    ch = VIEW_H / ROWS
    cx = ((np.arange(COLS * SX) + 0.5) / SX - COLS / 2) * ch * CW / LH
    cy = -((np.arange(ROWS * SY) + 0.5) / SY - ROWS / 2) * ch
    X, Y = np.meshgrid(cx, cy)
    d = np.linalg.norm(LOOK - EYE)
    rd = norm(fwd * d + right * X[..., None] + up * Y[..., None]).reshape(-1, 3)
    return np.broadcast_to(EYE, rd.shape).copy(), rd


def march(ro, rd, f, t0, t1):
    t, hit = t0.copy(), np.zeros(len(t0), bool)
    live = np.flatnonzero(t0 < t1)
    for _ in range(220):
        if not live.size:
            break
        d = f(ro[live] + rd[live] * t[live, None])
        done = d < 6e-4
        hit[live[done]] = True
        t[live] = t[live] + np.where(done, 0, d)
        live = live[~done & (t[live] < t1[live])]
    return hit, t


def soft_shadow(p, light, f, k, far):
    res, t = np.ones(len(p)), np.full(len(p), 0.03)
    live = np.arange(len(p))
    for _ in range(80):
        if not live.size:
            break
        d = f(p[live] + light * t[live, None])
        res[live] = np.minimum(res[live], k * d / t[live])
        t[live] = t[live] + np.clip(d, 0.01, 0.15)
        live = live[(res[live] > 0.01) & (t[live] < far)]
    return np.clip(res, 0, 1)


def occlusion(p, n, f):
    occ, w = 0, 1.0
    for i in range(1, 6):
        h = 0.02 + 0.07 * i
        occ = occ + (h - f(p + n * h)) * w
        w *= 0.75
    return np.clip(1 - 1.6 * occ, 0, 1)


def normal(p, f):
    e = np.array([[1, -1, -1], [-1, -1, 1], [-1, 1, -1], [1, 1, 1]], float)
    return norm(sum(k * f(p + k * 1e-3)[:, None] for k in e))


def shade(theta, ro, rd):
    """Material (0 none, 1 skin, 2 stem, 3 leaf, 4 shadow), brightness and highlight per sample."""
    R = rotation(theta)

    def f(p):
        body, stem, leaf, _, _ = parts((p - CENTER) @ R)
        return np.minimum(smin(body, stem, 0.06), leaf)

    oc = ro - CENTER
    b = (oc * rd).sum(1)
    disc = b * b - ((oc * oc).sum(1) - 1.9**2)
    root = np.sqrt(np.maximum(disc, 0))
    t0 = np.where(disc > 0, np.maximum(-b - root, 0), np.inf)
    hit, t = march(ro, rd, f, t0, -b + root)

    mat, lum, spec = np.zeros(len(rd), int), np.zeros(len(rd)), np.zeros(len(rd))
    p = ro[hit] + rd[hit] * t[hit, None]
    n, v = normal(p, f), -rd[hit]
    body, stem, leaf, lu, lv = parts((p - CENTER) @ R)
    m = np.where(leaf < np.minimum(body, stem), 3, np.where(stem < body, 2, 1))
    sh = soft_shadow(p + n * 0.01, L_KEY, f, 9, 4)
    ao = occlusion(p, n, f)
    ndv = np.clip((n * v).sum(1), 0, 1)
    fill = np.clip(n @ L_FILL, 0, 1)

    hl = np.clip((n * norm(L_KEY + v)).sum(1), 0, 1) ** 44 * sh
    skin = 0.06 + 0.82 * np.clip((n @ L_KEY + 0.2) / 1.2, 0, 1) ** 1.3 * (0.25 + 0.75 * sh) + 0.14 * fill
    skin = (skin + 0.22 * (1 - ndv) ** 2.5) * (0.4 + 0.6 * ao) + 0.5 * hl
    q = (p - CENTER) @ R
    skin = skin * (1 - SEAM_DARK * np.exp(-((q[:, 0] / SEAM_LINE) ** 2)) * smoothstep(-0.1, 0.4, q[:, 2]))  # the seam's line

    nn = np.where(((n * v).sum(1) < 0)[:, None], -n, n)
    leafl = 0.08 + 0.78 * np.clip(nn @ L_KEY, 0, 1) * sh + 0.22 * np.clip(-(nn @ L_KEY), 0, 1)
    leafl = (leafl + 0.12 * fill) * (0.5 + 0.5 * ao)
    leafl = np.where((np.abs(lv) < 0.035) & (lu > 0.05), leafl * 1.3, leafl)   # midrib

    steml = (0.12 + 0.75 * np.clip((n @ L_KEY + 0.4) / 1.4, 0, 1) * sh) * (0.5 + 0.5 * ao)

    lum[hit] = np.select([m == 1, m == 2], [skin, steml], leafl)
    spec[hit] = np.where(m == 1, hl, 0)
    mat[hit] = m

    if not SHADOW:
        return mat, lum, spec
    # A soft shadow on an unseen floor under it.
    floor = np.flatnonzero(~hit & (rd[:, 1] < 0))
    g = ro[floor] + rd[floor] * ((GROUND - ro[floor, 1]) / rd[floor, 1])[:, None]
    dark = smoothstep(1.05, 0.2, np.hypot(g[:, 0] - 0.12, (g[:, 2] + 0.1) * 1.15))
    mat[floor[dark > 0.05]] = 4
    lum[floor] = 0.26 * dark
    return mat, lum, spec


def glyphs():
    k = 12
    font = ImageFont.truetype(FONT, round(EM * k))
    out = []
    for ch in CHARS:
        im = Image.new("L", (CW * k, LH * k))
        ImageDraw.Draw(im).text((0, BASE * k), ch, font=font, fill=255, anchor="ls")
        out.append(np.asarray(im.resize((SX, SY), Image.BOX), float) / 255)
    return np.array(out).reshape(len(CHARS), -1)


def cells(a):
    return a.reshape(ROWS, SY, COLS, SX).transpose(0, 2, 1, 3).reshape(ROWS * COLS, SY * SX)


BAYER = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16 - 0.5


def ramp(ink):
    """Interior characters from faint to dense, at evenly spaced ink."""
    dens = ink.mean(1)
    cand = [CHARS.index(c) for c in RAMP]
    out = []
    for level in np.linspace(0, dens[cand].max(), 28):
        best = min(cand, key=lambda i: abs(dens[i] - level))
        if not out or best != out[-1]:
            out.append(best)
    return np.array(out)


def to_text(mat, lum, spec, ink, dense):
    """One frame as rows of (character, color) per cell: the inside by
    brightness, the outline by the glyph whose ink matches the covered samples."""
    mat, lum, spec = cells(mat), cells(np.clip(lum, 0, 1)), cells(spec)
    obj = ((mat >= 1) & (mat <= 3)).astype(float)
    shape = ink / np.maximum(ink.max(1, keepdims=True), 1e-6)
    edge = np.array([CHARS.index(c) for c in EDGE])
    out = []
    for i in range(ROWS * COLS):
        counts = np.bincount(mat[i], minlength=5)[1:]
        if not counts.any():
            out.append((" ", None))
            continue
        m = 1 + counts.argmax()
        level = lum[i][mat[i] == m].mean()
        ramp_ = RAMPS[m]
        if m == 4:
            ch = FLOOR[min(int(level / 0.26 * len(FLOOR)), len(FLOOR) - 1)]
        elif obj[i].mean() < 0.8:
            ch = CHARS[edge[((obj[i][None] - shape[edge]) ** 2).mean(1).argmin()]]
        else:
            step = level**0.9 * (len(dense) - 1) + BAYER[i // COLS % 4, i % COLS % 4] * 0.7
            ch = CHARS[dense[min(1 + int(step), len(dense) - 1)]]
        if ch == " ":
            out.append((" ", None))
            continue
        if m == 1:
            top = spec[i][mat[i] == 1].mean()
            idx = 7 if top > 0.4 else 6 if top > 0.18 else min(int(level * 6.5), 5)
        else:
            idx = min(int(level * len(ramp_) * 1.15), len(ramp_) - 1)
        out.append((ch, ramp_[idx]))
    return [out[r * COLS:(r + 1) * COLS] for r in range(ROWS)]


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def svg(frames):
    colors = sorted({c for fr in frames for row in fr for _, c in row if c})
    name = {c: chr(97 + i) if i < 26 else "c" + str(i) for i, c in enumerate(colors)}
    W, FH = PAD_X * 2 + COLS * CW, ROWS * LH
    H = BAR + PAD_Y * 2 + FH
    top = BAR + PAD_Y
    lines = []
    for f, frame in enumerate(frames):
        for r, row in enumerate(frame):
            runs, cur = [], None
            for col, (ch, c) in enumerate(row):
                if ch == " ":
                    if cur:
                        cur[2] += " "
                elif cur and cur[1] == c:
                    cur[2] += ch
                else:
                    cur = [col, c, ch]
                    runs.append(cur)
            if runs:
                spans = "".join(
                    f'<tspan x="{PAD_X + c0 * CW}" class="{name[c]}">{esc(t.rstrip())}</tspan>' for c0, c, t in runs)
                lines.append(f'<text y="{top + f * FH + r * LH + BASE:g}">{spans}</text>')
    style = "".join(f".{name[c]}{{fill:{c}}}" for c in colors)
    dots = "".join(f'<circle cx="{22 + 20 * i}" cy="{BAR / 2}" r="6" fill="{c}"/>'
                   for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="title">
<title id="title">Plum: an ASCII plum turning in a terminal window</title>
<style>
.g{{font-family:Menlo,"SF Mono",ui-monospace,"DejaVu Sans Mono",Consolas,"Liberation Mono",monospace;font-size:{EM:.3f}px;white-space:pre}}
.s{{animation:spin {SECONDS}s steps({FRAMES}) infinite}}
@keyframes spin{{to{{transform:translateY(-{FRAMES * FH}px)}}}}
@media (prefers-reduced-motion:reduce){{.s{{animation:none}}}}
{style}
</style>
<defs><clipPath id="view"><rect x="0" y="{top}" width="{W}" height="{FH}"/></clipPath></defs>
<rect width="{W}" height="{H}" rx="14" fill="{BACK}"/>
<path d="M0 {BAR}V14A14 14 0 0 1 14 0H{W - 14}A14 14 0 0 1 {W} 14V{BAR}Z" fill="{BAR_FILL}"/>
<path d="M0 {BAR}H{W}" stroke="{LINE}"/>
<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="13.5" fill="none" stroke="{LINE}"/>
{dots}
<text x="{W / 2:g}" y="{BAR / 2 + 4.5:g}" text-anchor="middle" fill="{TITLE}" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif" font-size="13">plum</text>
<g clip-path="url(#view)"><g class="s g" xml:space="preserve">
{chr(10).join(lines)}
</g></g>
</svg>
"""


def preview(frames, path, picks):
    """The picked frames side by side, drawn with Menlo as a browser would."""
    k = 2
    font = ImageFont.truetype(FONT, round(EM * k))
    w, h = (PAD_X * 2 + COLS * CW) * k, (PAD_Y * 2 + ROWS * LH) * k
    sheet = Image.new("RGB", (w * len(picks), h), BACK)
    draw = ImageDraw.Draw(sheet)
    for i, f in enumerate(picks):
        for r, row in enumerate(frames[f]):
            for c, (ch, color) in enumerate(row):
                if color:
                    draw.text((i * w + (PAD_X + c * CW) * k, (PAD_Y + r * LH + BASE) * k), ch,
                              font=font, fill=color, anchor="ls")
    sheet.save(path)


def render(count, ink, dense):
    ro, rd = rays()
    return [to_text(*shade(0.9 + 2 * math.pi * f / count, ro, rd), ink, dense) for f in range(count)]


def swift(frames):
    """The frames as Swift: a line per row, its characters, a tab, and a
    palette index per character ('.' for none)."""
    colors = sorted({c for fr in frames for row in fr for _, c in row if c})
    code = {c: "0123456789abcdefghijklmnopqrstuvwxyz"[i] for i, c in enumerate(colors)}
    body = "\n".join("".join(ch for ch, _ in row) + "\t" + "".join(code[c] if c else "." for _, c in row)
                     for fr in frames for row in fr)
    assert '"""###' not in body and "\\###" not in body
    palette = ", ".join("0x" + c[1:] for c in colors)
    return f"""// Made by scripts/readme-plum.py; don't edit.
extension AsciiPlum {{
    static let shared = AsciiPlum(cols: {COLS}, rows: {ROWS}, palette: [{palette}], text: ###\"\"\"
{body}
\"\"\"###)
}}
"""


def main():
    global COLS, ROWS, VIEW_H, LOOK, SHADOW, SEAM_DEPTH, SEAM_WIDTH, SEAM_DARK, SEAM_LINE
    ink = glyphs()
    dense = ramp(ink)
    print("ramp:", "".join(CHARS[i] for i in dense))
    frames = render(FRAMES, ink, dense)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(svg(frames))
    print(f"{OUT} {OUT.stat().st_size / 1024:.0f} KB")
    if len(sys.argv) > 1:
        preview(frames, sys.argv[1], [int(a) for a in sys.argv[2:]] or [0, FRAMES // 4])

    # Small, framed tight and without the floor, for the app icon.
    COLS, ROWS, VIEW_H, LOOK, SHADOW = 28, 13, 2.8, np.array([0, 0.2, 0]), False
    # A cell is wide here: a deeper, wider seam so it still shows at icon sizes.
    SEAM_DEPTH, SEAM_WIDTH, SEAM_DARK, SEAM_LINE = 0.14, 0.18, 0.9, 0.13
    SWIFT_OUT.write_text(swift(render(36, ink, dense)))
    print(f"{SWIFT_OUT} {SWIFT_OUT.stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
