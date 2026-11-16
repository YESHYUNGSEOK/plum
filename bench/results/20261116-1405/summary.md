## 측정 환경

```
date: 2026-11-16 14:05:45
phases: launch
grid: 122x46
load at start: (3.767578125, 5.59521484375, 5.8984375)
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
date: 2026-11-16 14:07:46
phases: throughput
grid: 122x46
load at start: (3.357421875, 4.759765625, 5.515625)
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
date: 2026-11-16 14:15:09
phases: latency
grid: 122x46
load at start: (2.609375, 3.66943359375, 4.63427734375)
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
date: 2026-11-16 14:19:46
phases: memory
grid: 122x46
load at start: (2.26416015625, 2.97119140625, 4.0537109375)
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
date: 2026-11-16 14:30:16
phases: tabs
grid: 122x46
load at start: (1.58056640625, 2.18359375, 2.978515625)
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

## 실행 시간 (ms)

| 구간 | Plum | Ghostty | Ghostty ÷ Plum |
|---|---|---|---|
| 실행 요청 → 창이 화면에 뜸 | **286** [283–289] (254–345), n=15 | **342** [322–359] (289–638), n=15 | 1.20× |
| 실행 요청 → 셸 프로세스 시작 | **253** [252–256] (222–269), n=15 | **239** [224–258] (199–271), n=15 | 0.95× |

제외한 표본: 0개 (창이 화면에 보이지 않음).

## 출력 처리 속도 (MB/s, 클수록 빠름)

| 데이터 | Plum | Ghostty | Plum ÷ Ghostty |
|---|---|---|---|
| ascii | **114** [113–137] (84–175), n=10 | **103** [101–107] (98–115), n=10 | 1.11× |
| scrolling | **83** [82–83] (67–84), n=10 | **70** [69–72] (69–76), n=10 | 1.18× |
| dense_cells | **136** [136–137] (127–138), n=10 | **60** [60–61] (36–61), n=10 | 2.26× |
| unicode | **213** [202–220] (167–241), n=10 | **125** [124–126] (123–128), n=10 | 1.71× |
| cursor_motion | **212** [207–214] (143–216), n=10 | **111** [110–112] (110–113), n=10 | 1.91× |
| scroll_region | **83** [82–83] (80–85), n=10 | **62** [62–62] (61–66), n=10 | 1.33× |
| sync_tui | **117** [116–118] (115–118), n=10 | **71** [70–71] (58–74), n=10 | 1.66× |

제외한 표본: 0개 (측정 중 다른 앱이 앞에 있었음).

## 키 입력 → 화면 표시 지연, 연속 입력 (ms, 작을수록 빠름)

| | Plum | Ghostty |
|---|---|---|
| 중앙값 [사분위] (범위) | **16.2** [13.3–19.5] (9.6–38.7), n=400 | **23.5** [18.6–30.1] (14.5–41.3), n=400 |
| 평균 | 16.8 | 24.5 |
| 95번째 백분위 | 24.6 | 35.7 |

블록별 중앙값 (두 앱을 번갈아 측정):

| 블록 | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| plum | 13.4 | 14.2 | 13.8 | 13.5 | 18.0 | 19.7 | 18.5 | 18.7 |
| ghostty | 20.5 | 19.0 | 19.5 | 18.6 | 27.6 | 29.8 | 30.1 | 30.2 |

## 메모리와 유휴 CPU (터미널 1개, 화면에 보이는 상태)

| 항목 | plum | ghostty | ghostty-noblink |
|---|---|---|---|
| 실행 10초 뒤 메모리 (MB) | **54.8** [54.8–54.9] (54.8–55.0), n=4 | **178.4** [156.8–178.6] (91.9–178.9), n=4 | **176.2** (174.3–178.2), n=2 |
| 실행 60초 뒤 메모리 (MB) | **52.0** [51.5–54.7] (51.4–61.5), n=4 | **181.1** [152.9–186.8] (85.4–187.0), n=4 | **133.1** (91.9–174.2), n=2 |
| 최대 메모리 (MB) | **158.9** [153.7–164.0] (153.3–164.1), n=4 | **199.4** [193.8–201.5] (181.0–203.4), n=4 | **193.1** (182.7–203.5), n=2 |
| 유휴 30초 동안 쓴 CPU (ms) | **17** [1–271] (1–985), n=4 | **293** [220–305] (3–340), n=4 | **364** (290–439), n=2 |

제외한 표본: 0개.

## 터미널 10개

| 항목 | Plum | Ghostty |
|---|---|---|
| 터미널 1개일 때 (MB) | **55.9** (55.7–56.0), n=2 | **177.2** (176.2–178.2), n=2 |
| 터미널 10개일 때 (MB) | **59.8** (59.6–60.0), n=2 | **571.9** (566.2–577.5), n=2 |

터미널이 10개가 아니었던 실행(제외): ghostty 9개, plum 9개.

## 대량 출력 뒤 메모리 (스크롤백이 찬 상태, 1회)

| 앱 | 메모리 (MB) | 최대 (MB) |
|---|---|---|
| plum | 100.8 | 220.7 |
| ghostty | 574.1 | 580.7 |

