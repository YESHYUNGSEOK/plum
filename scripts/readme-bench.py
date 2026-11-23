#!/usr/bin/env python3
"""Draws the README's Plum-vs-Ghostty chart: bars that fill, in a window
like the README's plum. Writes docs/assets/bench.svg and bench.ko.svg.

The numbers are the medians in docs/benchmarks/2026-11-17.md (memory,
latency, idle CPU) and 2026-11-20.md (output, measured 2026-11-23); change
them here when a new measurement replaces them, then run this again.
"""
from pathlib import Path

# (label en, label ko, unit, Plum, Ghostty): lower is better
LEFT = [
    ("Memory, 1 terminal", "메모리, 터미널 1개", "MB", 37, 148),
    ("Memory, 10 terminals", "메모리, 터미널 10개", "MB", 49, 214),
    ("Key press → on screen", "키 입력 → 화면", "ms", 18.5, 24.0),
    ("Idle CPU per 30 s", "쉬는 동안 CPU (30초)", "ms", 1, 107),
]
# (label en, label ko, Plum ÷ Ghostty): higher is better
RIGHT = [
    ("Dense colors", "색이 많은 화면", 2.64),
    ("Unicode", "유니코드", 1.42),
    ("Scrolling", "스크롤", 1.32),
    ("Cursor movement", "커서 이동", 1.29),
    ("TUI redraw", "TUI 다시 그리기", 1.17),
    ("Scroll region", "스크롤 영역", 1.07),
    ("Plain text", "일반 텍스트", 1.05),
]
TEXT = {
    "en": dict(title="Plum vs Ghostty 1.4.0", lower="lower is better", output="Output throughput",
               higher="Ghostty = 1×, higher is better", times="×",
               note="Same Mac (M4 Pro), taking turns. Memory, latency, CPU: 2026-11-17. Output: 2026-11-23. Details in docs/benchmarks."),
    "ko": dict(title="Plum vs Ghostty 1.4.0", lower="낮을수록 좋음", output="출력 처리 속도",
               higher="Ghostty = 1배, 높을수록 좋음", times="배",
               note="같은 Mac(M4 Pro)에서 번갈아 측정. 메모리·지연·CPU 2026-11-17, 출력 2026-11-23. 자세한 내용은 docs/benchmarks."),
}

W, BAR = 960, 34                    # width, window title bar
SANS = "-apple-system,BlinkMacSystemFont,'Apple SD Gothic Neo','Segoe UI',Helvetica,Arial,sans-serif"
MONO = "Menlo,'SF Mono',ui-monospace,Consolas,monospace"
BACK, BAR_FILL, LINE, DIM, TEXT_C = "#141417", "#1E1E22", "#2C2C32", "#8E8E99", "#E6E6EB"
PLUM, GHOSTTY, TRACK = "url(#plum)", "#4A4A55", "#1E1E22"
CYCLE = 8                            # seconds: fill, hold, fade, again


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def value(n, unit):
    if unit in ("배", "×"):
        return f"{n:.2f}{unit}"
    return f"{n:.1f} {unit}" if isinstance(n, float) else f"{n} {unit}"


def draw(lang):
    t = TEXT[lang]
    out, order = [], 0

    def bar(x, y, width, h, fill, label, label_fill):
        nonlocal order
        delay = 0.25 + 0.07 * order
        order += 1
        out.append(f'<rect x="{x}" y="{y}" width="{max(width, 3):.1f}" height="{h}" rx="{h / 2}" fill="{fill}" '
                   f'class="b" style="animation-delay:{delay:.2f}s"/>')
        if label:
            out.append(f'<text x="{x + max(width, 3) + 8:.1f}" y="{y + h - 1.5}" class="v" fill="{label_fill}" '
                       f'style="animation-delay:{delay:.2f}s">{esc(label)}</text>')

    def heading(x, y, right, title, hint):
        out.append(f'<text x="{x}" y="{y}" class="h">{esc(title)}</text>')
        out.append(f'<text x="{right}" y="{y}" class="n" text-anchor="end">{esc(hint)}</text>')

    # left: two bars per measure, scaled to the larger one
    lx, lw, label_w, top = 32, 420, 64, BAR + 104
    span = lw - label_w - 78
    y = top
    for en, ko, unit, plum, ghostty in LEFT:
        heading(lx, y, lx + lw, en if lang == "en" else ko, t["lower"])
        for i, (name, n, fill, vfill) in enumerate([("Plum", plum, PLUM, TEXT_C), ("Ghostty", ghostty, GHOSTTY, DIM)]):
            row = y + 14 + i * 22
            out.append(f'<text x="{lx}" y="{row + 11}" class="r">{name}</text>')
            out.append(f'<rect x="{lx + label_w}" y="{row}" width="{span}" height="13" rx="6.5" fill="{TRACK}"/>')
            bar(lx + label_w, row, span * n / max(plum, ghostty), 13, fill, value(n, unit), vfill)
        y += 84

    # right: Plum's ratio against Ghostty's 1×, scaled to the largest ratio
    rx, rw, label_w = 500, 428, 132
    span = rw - label_w - 58
    most = max(r for *_, r in RIGHT)
    heading(rx, top, rx + rw, t["output"], t["higher"])
    for i, (en, ko, ratio) in enumerate(RIGHT):
        row = top + 14 + i * 44
        out.append(f'<text x="{rx}" y="{row + 18}" class="r">{esc(en if lang == "en" else ko)}</text>')
        for j, (n, fill, vfill, h) in enumerate([(ratio, PLUM, TEXT_C, 13), (1, GHOSTTY, DIM, 8)]):
            ry = row + (0 if j == 0 else 17)
            out.append(f'<rect x="{rx + label_w}" y="{ry}" width="{span}" height="{h}" rx="{h / 2}" fill="{TRACK}"/>')
            # Ghostty's bar is the same 1× in every row; the heading says so
            bar(rx + label_w, ry, span * n / most, h, fill, value(n, t["times"]) if j == 0 else None, vfill)

    height = max(y, top + 14 + len(RIGHT) * 44) + 30
    legend = (f'<rect x="{W - 250}" y="{BAR + 33}" width="12" height="12" rx="3" fill="{PLUM}"/>'
              f'<text x="{W - 232}" y="{BAR + 43.5}" class="r">Plum</text>'
              f'<rect x="{W - 172}" y="{BAR + 33}" width="12" height="12" rx="3" fill="{GHOSTTY}"/>'
              f'<text x="{W - 154}" y="{BAR + 43.5}" class="r">Ghostty 1.4.0</text>')
    dots = "".join(f'<circle cx="{22 + 20 * i}" cy="{BAR / 2}" r="6" fill="{c}"/>'
                   for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]))
    alt = (f"{t['title']}: " + "; ".join(f"{en} {value(p, u)} vs {value(g, u)}" for en, _, u, p, g in LEFT)
           + "; output " + ", ".join(f"{en} {r}x" for en, _, r in RIGHT))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" viewBox="0 0 {W} {height}" role="img" aria-labelledby="title">
<title id="title">{esc(alt)}</title>
<defs><linearGradient id="plum" x1="0" x2="1"><stop offset="0" stop-color="#8143C6"/><stop offset="1" stop-color="#C58AF9"/></linearGradient></defs>
<style>
text{{font-family:{SANS}}}
.h{{font-size:15px;font-weight:600;fill:{TEXT_C}}}
.n{{font-size:12px;fill:{DIM}}}
.r{{font-size:13px;fill:#B9B9C2}}
.v{{font-family:{MONO};font-size:12.5px;animation:show {CYCLE}s infinite}}
.b{{transform-box:fill-box;transform-origin:0 50%;animation:fill {CYCLE}s cubic-bezier(.2,.8,.2,1) infinite}}
@keyframes fill{{0%{{transform:scaleX(0);opacity:1}}16%,90%{{transform:scaleX(1);opacity:1}}100%{{transform:scaleX(1);opacity:0}}}}
@keyframes show{{0%,10%{{opacity:0}}18%,90%{{opacity:1}}100%{{opacity:0}}}}
@media (prefers-reduced-motion:reduce){{.b,.v{{animation:none}}}}
</style>
<rect width="{W}" height="{height}" rx="14" fill="{BACK}"/>
<path d="M0 {BAR}V14A14 14 0 0 1 14 0H{W - 14}A14 14 0 0 1 {W} 14V{BAR}Z" fill="{BAR_FILL}"/>
<path d="M0 {BAR}H{W}" stroke="{LINE}"/>
<rect x="0.5" y="0.5" width="{W - 1}" height="{height - 1}" rx="13.5" fill="none" stroke="{LINE}"/>
{dots}
<text x="{W / 2:g}" y="{BAR / 2 + 4.5:g}" text-anchor="middle" fill="{DIM}" font-size="13">plum</text>
<text x="32" y="{BAR + 46}" font-size="22" font-weight="700" fill="{TEXT_C}">{esc(t["title"])}</text>
{legend}
<path d="M32 {BAR + 66}H{W - 32}" stroke="{LINE}"/>
{chr(10).join(out)}
<text x="32" y="{height - 16}" class="n">{esc(t["note"])}</text>
</svg>
'''


if __name__ == "__main__":
    assets = Path(__file__).resolve().parent.parent / "docs" / "assets"
    for lang, name in [("en", "bench.svg"), ("ko", "bench.ko.svg")]:
        (assets / name).write_text(draw(lang))
        print("wrote", assets / name)
