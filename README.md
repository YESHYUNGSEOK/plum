# Plum

프로젝트(git 저장소)를 등록하고 워크스페이스를 추가하면 git worktree를 만들어 주고, 그 안에서 AI 코딩 에이전트를 돌릴 터미널까지 한 창에 담은 macOS 앱이다. Orca의 핵심만 남기고 네이티브로 가볍게 만드는 것이 목표다.

상태: **프로토타입**. 설계는 [`docs/superpowers/specs/2026-11-16-plum-design.md`](docs/superpowers/specs/2026-11-16-plum-design.md)에 있다.

## 빌드와 실행

필요한 것: macOS 14 이상, Xcode. Apple Silicon Mac과 Xcode 16.4에서 빌드를 확인했다.

```sh
./scripts/build-vt.sh   # 처음 한 번. Zig 0.17.0과 libghostty-vt 1.0.1 소스를 받아 빌드한다(네트워크 필요)
./scripts/bundle.sh     # build/Plum.app 생성 (릴리스 빌드, ad-hoc 서명)
open build/Plum.app
swift test              # 자동 테스트
```

`build-vt.sh`는 Zig 압축 파일의 SHA-256을 확인하고, 내려받은 것은 `.tools/`에만 둔다(시스템에 설치하지 않는다).

## 쓰는 법

1. **프로젝트 추가**(⌘O): git 저장소 폴더를 고른다. 사이드바에 프로젝트와 `main`(원래 체크아웃)이 생긴다.
2. **프로젝트 설정**(프로젝트 이름 옆 슬라이더 아이콘): 워크스페이스를 만들 때 할 일을 정한다.
   - 복사할 파일: 기본 체크아웃에서 새 워크트리로 복사할 git 밖의 파일. 한 줄에 glob 하나. 예: `.env*`
   - 준비 명령: 예: `pnpm install`
   - 에이전트 명령: 예: `claude --settings "$PLUM_CLAUDE_SETTINGS"` ("Claude Code 명령 넣기" 버튼)
3. **워크스페이스 추가**(⌘N 또는 프로젝트 옆 +): 이름을 넣으면 `<워크스페이스 위치>/<프로젝트>/<이름>`에 워크트리와 브랜치를 만들고, 파일을 복사하고, 첫 터미널 탭에서 `준비 명령 && 에이전트 명령`을 실행한다.
4. **정리**(워크스페이스 우클릭):
   - 아카이브: 워크트리 폴더를 지우고 브랜치는 남긴다. 나중에 복원할 수 있다.
   - 삭제: 워크트리 폴더와 로컬 브랜치를 지운다.
   - 커밋하지 않은 변경이나 어느 원격에도 없는 커밋이 있으면 목록을 보여 주고 다시 확인한다. 이때 기본 버튼은 "취소"다.

단축키: 새 탭 ⌘T, 탭 닫기 ⌘W, 탭 이동 ⌘1~9 · ⇧⌘[ · ⇧⌘], 글자 크기 ⌘+ · ⌘- · ⌘0, 사이드바 ⌃⌘S, 줄 처음/끝 ⌘← · ⌘→, 단어 이동 ⌥← · ⌥→, 줄 지우기 ⌘⌫.

설정(⌘,): 글꼴, 글꼴 크기, 워크스페이스 위치(기본 `~/plum/workspaces`), 브랜치 접두사(예: `eric/`).

## 에이전트 상태

탭과 사이드바의 점으로 표시한다: 파랑 = 작업 중, 주황 = 입력 대기, 초록 = 완료. 보고 있지 않은 탭이 입력 대기나 완료가 되면 Dock 배지에 개수를 띄우고 Dock 아이콘을 한 번 튕긴다.

상태는 세 가지 경로로 들어온다.

| 경로 | 설정 | 비고 |
|---|---|---|
| Claude Code 훅 | `claude --settings "$PLUM_CLAUDE_SETTINGS"`로 실행 | 작업 중·입력 대기·완료를 모두 알린다. `~/.claude/settings.json`은 건드리지 않는다 |
| OSC 7501 (프로그램 상태 표준) | 없음 | 이 표준을 지원하는 프로그램이면 자동 |
| OSC 9 / OSC 777 알림, 벨 | 없음 | 보고 있지 않은 탭에서만 "입력 대기"로 표시 |

Plum은 터미널마다 `PLUM_SOCKET`, `PLUM_TAB_ID`, `PLUM_CLAUDE_SETTINGS` 환경 변수를 넣는다. 훅은 macOS 기본 `nc`로 `<탭 ID> <working|waiting|done|idle>` 한 줄을 소켓에 보낸다. 다른 에이전트도 같은 한 줄을 보내면 연동된다.

## 저장 위치

- 앱 상태: `~/Library/Application Support/dev.plum.Plum/state.json`
- 훅 설정과 소켓: 같은 폴더의 `claude-hooks.json`, `plum.sock`
- 워크트리: 설정의 워크스페이스 위치 아래

## 확인한 것과 확인하지 못한 것

2026-11-16, MacBook Pro (M4 Pro, macOS 26.3.1)에서 확인했다.

**실행해서 확인한 것**

- 자동 테스트 15개 통과: 워크트리 생성(새 브랜치·기존 브랜치·한글 이름), 파일 복사와 저장소 밖 패턴 거부, 변경이 있는 워크트리는 강제 옵션 없이 지워지지 않음, 푸시 안 된 커밋 보고, 기본 체크아웃과 워크트리가 아닌 폴더는 지우지 않음, 앱 밖에서 지워진 폴더의 아카이브·복원, 상태 메시지 파싱, 상태 파일 손상 시 원본 보존.
- 실제 앱에서(테스트용 조작 소켓과 창 스크린샷으로): 프로젝트 등록 → 워크스페이스 생성 → `.env.local` 복사 → 준비 명령 실행, 아카이브·복원·삭제, 탭 열기·닫기·전환, 셸 종료 시 탭 닫힘과 좀비 프로세스 없음.
- 렌더링: 굵게·기울임·밑줄·취소선·반전·흐리게, 16색·256색·트루컬러, 한글 2칸 폭, 이모지(가족·국기 같은 묶음 포함), 파워라인 프롬프트, vim 전체 화면, Claude Code의 폴더 신뢰 확인 화면.
- 키 입력 인코딩(`cat -v`로 확인): 일반 글자, 방향키, Enter, Esc, Ctrl+A, Ctrl+C, Shift+Tab, ⌥←, ⌘←.
- 에이전트 상태: 소켓 메시지, OSC 7501, 벨이 사이드바에 반영됨. 잘못된 메시지와 모르는 탭 ID는 무시됨. 소켓 파일 권한 0600.
- 보이지 않는 창은 그리지 않는 규칙: 화면에 보이는 상태로 실행하면 터미널이 그려지고, 창을 최소화한 동안 나온 출력이 창을 되돌린 뒤 화면에 나타남.
- 실제 Claude Code 2.1.325: `claude --settings "$PLUM_CLAUDE_SETTINGS" -p …` 한 번 실행에서 대기 → 작업 중 → 완료 → 대기로 바뀜.

**확인하지 못한 것 — 직접 써 보며 확인이 필요하다**

- **한글 입력(IME)**: 조합 중 글자 표시와 조합 중 Enter 처리는 구현했지만, 실제 키보드 입력으로는 한 번도 확인하지 못했다. 키 입력 확인은 합성 이벤트로 했고 이 방식은 입력기를 거치지 않는다.
- **마우스**: 드래그 선택은 내부 함수 호출로만 확인했다. 실제 마우스 드래그·더블클릭·휠 스크롤은 확인하지 못했다.
- **복사/붙여넣기, 여러 줄 붙여넣기 확인 창, 대화상자와 메뉴**: 화면 조작으로는 확인하지 못했다.
- **macOS 알림**: 이 빌드(ad-hoc 서명)에서는 시스템이 "이 앱에는 알림이 허용되지 않음"으로 거부했다. Developer ID로 서명한 뒤 다시 확인해야 한다. 그때까지는 Dock 배지와 Dock 튕김이 대신한다.
- **Claude Code 대화형 화면**: 폴더 신뢰 확인 화면까지만 봤다(신뢰 여부를 대신 승인하지 않았다). 권한 요청 시 "입력 대기"로 바뀌는지는 확인하지 못했다.
- **Codex 연동**: 구현도 확인도 하지 않았다.

## 측정 결과

Ghostty 1.3.1과 같은 Mac(M4 Pro, 내장 120Hz 화면)에서 번갈아 쟀다. 값은 중앙값이고, 표본 수·흩어짐·측정 방법·한계는 [`docs/benchmarks/2026-11-16.md`](docs/benchmarks/2026-11-16.md)에 있다.

| 항목 | Plum | Ghostty | 표본 |
|---|---|---|---|
| 앱 크기 | 2.1MB | 62MB | |
| 실행 → 창이 뜸 | 286ms | 342ms | 각 15회 |
| 실행 → 셸 시작 | 253ms | 239ms | 각 15회 |
| 출력 처리 속도 (7종) | Ghostty의 1.11~2.26배 | | 종류별 각 10회 |
| 키 입력 → 화면 표시 | 16.2ms, 17.0ms | 23.5ms, 28.2ms | 두 세션, 300~400회씩 |
| 5초 쉬고 난 첫 키 | 15.7ms (1회 132ms) | 21.6ms | 48회, 36회 |
| 메모리, 터미널 1개, 보이는 유휴 상태 | 52MB | 181MB (85~187MB) | 각 4회 |
| 메모리, 터미널 10개 | 59MB | 566MB | 각 5회 |
| 유휴 CPU (30초) | 1~4ms | 약 290~340ms | 방해 없는 실행 기준 |

- 셸이 시작되는 시점은 Ghostty가 조금 빠르다.
- 키 입력 지연에는 키보드와 패널의 응답 시간이 들어 있지 않다. 두 앱의 차이를 보는 값이다.
- 그리는 동안에는 두 앱 모두 GPU 메모리 약 100MB를 더 쓴다. Plum은 화면이 바뀌지 않으면 몇 초 뒤 반환한다.
- 측정 중 Mac이 다른 작업에 쓰이고 있었다. 번갈아 재고 표본을 검사해 영향을 줄였지만 없애지는 못했다.

다시 재려면: `swiftc -O bench/plumbench.swift -o bench/plumbench && python3 bench/run.py all` (약 30분, 측정 창이 포커스를 가져간다).

## 아직 없는 것

터미널 내 검색, 마우스 보고(vim·htop 클릭)와 전체 화면 프로그램에서의 휠 스크롤, 링크 클릭, 밝은 테마, 재시작 후 탭 복원, 화면 분할, 기존 워크트리 가져오기, 앱을 꺼도 터미널이 살아 있는 세션 유지, 서명·공증·자동 업데이트, Intel Mac 빌드. 이유와 순서는 설계 문서 14장에 있다.

## 코드 구조

```
Sources/CPty/                  pty 생성 (forkpty + execve)
Sources/PlumKit/Terminal/      TerminalSession(pty·VT 상태), TerminalRenderer·GlyphAtlas(Metal), TerminalView(입력), KeyMap
Sources/PlumKit/Model/         Models·Store, Git, WorkspaceService, StatusServer, AppModel, DebugCommands
Sources/PlumKit/UI/            App(메뉴·알림), MainWindow, Sidebar, Sheets, AppActions(확인 창)
Sources/Plum/                  진입점
Vendor/                        libghostty-vt xcframework (build-vt.sh가 생성, git에는 넣지 않음)
```

VT 해석과 화면 상태는 [libghostty-vt](https://libghostty.tip.ghostty.org/) 1.0.1(MIT)에 맡기고, 렌더러·글꼴·입력·pty는 직접 만들었다. 외부 의존성은 이것 하나다.

### 스크립트로 앱 조작하기

`PLUM_DEBUG=1`로 실행하면 상태 소켓이 `debug …` 명령도 받는다. 위의 확인은 이 방법으로 했다. `PLUM_STATE_DIR`로 상태 폴더를 바꾸면 실제 상태를 건드리지 않는다.

```sh
PLUM_DEBUG=1 PLUM_STATE_DIR=/tmp/plum-dev build/Plum.app/Contents/MacOS/Plum &
printf 'debug state\n' | nc -w 3 -U /tmp/plum-dev/plum.sock
```

명령 목록은 `Sources/PlumKit/Model/DebugCommands.swift`에 있다.
