## Environment

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

Values are the **median** [Q1–Q3] (min–max), n = number of samples.

## Launch time (ms)

| Interval | Plum | Ghostty | Ghostty ÷ Plum |
|---|---|---|---|
| Launch request → window on screen | **286** [283–289] (254–345), n=15 | **342** [322–359] (289–638), n=15 | 1.20× |
| Launch request → shell process started | **253** [252–256] (222–269), n=15 | **239** [224–258] (199–271), n=15 | 0.95× |

Samples left out: 0 (window not on screen).

## Output throughput (MB/s, higher is faster)

| Data | Plum | Ghostty | Plum ÷ Ghostty |
|---|---|---|---|
| ascii | **114** [113–137] (84–175), n=10 | **103** [101–107] (98–115), n=10 | 1.11× |
| scrolling | **83** [82–83] (67–84), n=10 | **70** [69–72] (69–76), n=10 | 1.18× |
| dense_cells | **136** [136–137] (127–138), n=10 | **60** [60–61] (36–61), n=10 | 2.26× |
| unicode | **213** [202–220] (167–241), n=10 | **125** [124–126] (123–128), n=10 | 1.71× |
| cursor_motion | **212** [207–214] (143–216), n=10 | **111** [110–112] (110–113), n=10 | 1.91× |
| scroll_region | **83** [82–83] (80–85), n=10 | **62** [62–62] (61–66), n=10 | 1.33× |
| sync_tui | **117** [116–118] (115–118), n=10 | **71** [70–71] (58–74), n=10 | 1.66× |

Samples left out: 0 (another app was in front during the run).

## Key press → on screen latency, continuous typing (ms, lower is faster)

| | Plum | Ghostty |
|---|---|---|
| Median [quartiles] (range) | **16.2** [13.3–19.5] (9.6–38.7), n=400 | **23.5** [18.6–30.1] (14.5–41.3), n=400 |
| Mean | 16.8 | 24.5 |
| 95th percentile | 24.6 | 35.7 |

Median per block (the apps measured in turn):

| Block | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| plum | 13.4 | 14.2 | 13.8 | 13.5 | 18.0 | 19.7 | 18.5 | 18.7 |
| ghostty | 20.5 | 19.0 | 19.5 | 18.6 | 27.6 | 29.8 | 30.1 | 30.2 |

## Memory and idle CPU (1 terminal, on screen)

| Measure | plum | ghostty | ghostty-noblink |
|---|---|---|---|
| Memory 10 s after launch (MB) | **54.8** [54.8–54.9] (54.8–55.0), n=4 | **178.4** [156.8–178.6] (91.9–178.9), n=4 | **176.2** (174.3–178.2), n=2 |
| Memory 60 s after launch (MB) | **52.0** [51.5–54.7] (51.4–61.5), n=4 | **181.1** [152.9–186.8] (85.4–187.0), n=4 | **133.1** (91.9–174.2), n=2 |
| Peak memory (MB) | **158.9** [153.7–164.0] (153.3–164.1), n=4 | **199.4** [193.8–201.5] (181.0–203.4), n=4 | **193.1** (182.7–203.5), n=2 |
| CPU used in 30 s idle (ms) | **17** [1–271] (1–985), n=4 | **293** [220–305] (3–340), n=4 | **364** (290–439), n=2 |

Samples left out: 0.

## 10 terminals

| Measure | Plum | Ghostty |
|---|---|---|
| With 1 terminal (MB) | **55.9** (55.7–56.0), n=2 | **177.2** (176.2–178.2), n=2 |
| With 10 terminals (MB) | **59.8** (59.6–60.0), n=2 | **571.9** (566.2–577.5), n=2 |

Runs without 10 terminals (left out): ghostty with 9, plum with 9.

## Memory after heavy output (scrollback full, 1 run)

| App | Memory (MB) | Peak (MB) |
|---|---|---|
| plum | 100.8 | 220.7 |
| ghostty | 574.1 | 580.7 |

