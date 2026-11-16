## 측정 환경

```
date: 2026-11-16 14:35:29
phases: tabs
grid: 122x46
load at start: (3.31103515625, 3.62158203125, 3.423828125)
display: id 1, scale 2x, 120 Hz
ProductName:		macOS
ProductVersion:		26.3.1
ProductVersionExtra:	(a)
BuildVersion:		25D771280a
Apple M4 Pro
Ghostty 1.3.1

Version
  - version: 1.3.1
  - channel: stable
Build Config
  - Zig version   : 0.15.2
  - build mode    : .ReleaseFast
  - app runtime   : .none
  - font engine   : .coretext
  - renderer      : renderer.generic.Renderer(renderer.Metal)
  - libxev        : kqueue
date: 2026-11-16 14:41:48
phases: latency
grid: 122x46
load at start: (3.9755859375, 3.7744140625, 3.5927734375)
display: id 1, scale 2x, 120 Hz
ProductName:		macOS
ProductVersion:		26.3.1
ProductVersionExtra:	(a)
BuildVersion:		25D771280a
Apple M4 Pro
Ghostty 1.3.1

Version
  - version: 1.3.1
  - channel: stable
Build Config
  - Zig version   : 0.15.2
  - build mode    : .ReleaseFast
  - app runtime   : .none
  - font engine   : .coretext
  - renderer      : renderer.generic.Renderer(renderer.Metal)
  - libxev        : kqueue
date: 2026-11-16 14:46:05
phases: idle
grid: 122x46
load at start: (3.50537109375, 3.595703125, 3.54736328125)
display: id 1, scale 2x, 120 Hz
ProductName:		macOS
ProductVersion:		26.3.1
ProductVersionExtra:	(a)
BuildVersion:		25D771280a
Apple M4 Pro
Ghostty 1.3.1

Version
  - version: 1.3.1
  - channel: stable
Build Config
  - Zig version   : 0.15.2
  - build mode    : .ReleaseFast
  - app runtime   : .none
  - font engine   : .coretext
  - renderer      : renderer.generic.Renderer(renderer.Metal)
  - libxev        : kqueue
date: 2026-11-16 14:53:31
phases: latency_idle
grid: 122x46
load at start: (2.97314453125, 3.66748046875, 3.6240234375)
display: id 1, scale 2x, 120 Hz
ProductName:		macOS
ProductVersion:		26.3.1
ProductVersionExtra:	(a)
BuildVersion:		25D771280a
Apple M4 Pro
Ghostty 1.3.1

Version
  - version: 1.3.1
  - channel: stable
Build Config
  - Zig version   : 0.15.2
  - build mode    : .ReleaseFast
  - app runtime   : .none
  - font engine   : .coretext
  - renderer      : renderer.generic.Renderer(renderer.Metal)
  - libxev        : kqueue
```

표의 값은 **중앙값** [1사분위–3사분위] (최소–최대), n=표본 수 형식이다.

## 키 입력 → 화면 표시 지연, 연속 입력 (ms, 작을수록 빠름)

| | Plum | Ghostty |
|---|---|---|
| 중앙값 [사분위] (범위) | **17.0** [14.7–19.4] (10.4–31.4), n=300 | **28.2** [23.6–33.3] (15.5–45.1), n=350 |
| 평균 | 17.3 | 28.4 |
| 95번째 백분위 | 24.3 | 38.5 |

블록별 중앙값 (두 앱을 번갈아 측정):

| 블록 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| plum | 17.9 | 15.7 | 19.6 | 14.7 | 15.0 | 19.3 | — | — |
| ghostty | — | 26.9 | 28.0 | 27.9 | 31.1 | 28.3 | 28.1 | 26.6 |

## 키 입력 → 화면 표시 지연, 5초 쉬고 난 첫 키 (ms)

| | Plum | Ghostty |
|---|---|---|
| 중앙값 [사분위] (범위) | **15.7** [12.9–20.6] (11.0–131.8), n=48 | **21.6** [16.8–24.3] (14.4–32.3), n=36 |
| 평균 | 19.8 | 21.2 |
| 95번째 백분위 | 29.9 | 28.0 |

블록별 중앙값 (두 앱을 번갈아 측정):

| 블록 | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| plum | 16.5 | 15.0 | 14.7 | 18.2 |
| ghostty | — | 21.5 | 20.8 | 22.4 |

## 터미널 10개

| 항목 | Plum | Ghostty |
|---|---|---|
| 터미널 1개일 때 (MB) | **54.9** [54.7–55.0] (54.6–57.8), n=5 | **178.1** [178.0–178.2] (92.4–178.3), n=5 |
| 터미널 10개일 때 (MB) | **59.1** [59.0–59.4] (58.9–60.3), n=5 | **566.0** [483.4–577.4] (481.9–577.8), n=5 |

터미널이 10개가 아니었던 실행(제외): 없음.

