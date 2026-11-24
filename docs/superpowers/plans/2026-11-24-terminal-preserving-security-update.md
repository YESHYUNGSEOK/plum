# Terminal Preserving Security Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep existing terminals usable across the GUI update while new terminals use a hardened host.

**Architecture:** Version 3 uses a separate socket. A restricted version 1 client attaches only to the published 0.1.10 binary and never starts it. AppModel remembers which host owns each restored tab.

**Tech Stack:** Swift, AppKit, Unix domain sockets, Security.framework, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-24-terminal-preserving-security-update-design.md`

## Global Constraints

- Do not terminate or signal any of the eleven live terminal children during development or testing.
- Never launch a version 1 host from the new binary.
- Preserve saved tab IDs if either host is unavailable.
- The legacy host's same-user socket risk remains until it exits.

## Review Focus

- A non-Plum process at the legacy socket must be rejected before any request is sent.
- A disappeared legacy socket must not cause a replacement legacy host to launch.
- A missing host must not erase saved tab IDs.
- A restored legacy tab must park and close through its legacy client.
- A fresh tab must use the version 3 host even while legacy tabs exist.

---

### Task 1: Separate and authenticate hosts

**Files:** `Sources/PlumKit/Terminal/TerminalHost.swift`, `Tests/PlumKitTests/TerminalHostTests.swift`

**Interfaces:** Add `TerminalHost.legacySocketPath(for:)`; add a legacy-only `TerminalHostClient` initializer taking a socket path and pinned code hash, with version 1 handshake and no launch.

- [ ] Add tests for version 1 path, rejected fake host, and no legacy launch.
- [ ] Run focused tests and verify failure.
- [ ] Implement version 3 path and legacy-only client verification.
- [ ] Run focused tests and verify pass.

### Task 2: Route restored and new tabs

**Files:** `Sources/PlumKit/Model/AppModel.swift`, `Tests/PlumKitTests/NavigationTests.swift`

**Interfaces:** Track legacy-owned tab IDs, restore from both hosts, and choose the owner for park. New `openTab` always uses version 3.

- [ ] Add tests for dual-host restore, new tab routing, and saved-state preservation on a missing host.
- [ ] Run focused tests and verify failure.
- [ ] Implement the minimum AppModel routing and error handling.
- [ ] Run focused tests and verify pass.

### Task 3: Isolated migration and live switch

**Files:** Built app bundle and local test artifacts only.

- [ ] Run the full test suite and release build; verify app signature.
- [ ] Launch an isolated old host, create a shell, and reconnect with the new client; verify same PID and input/output.
- [ ] Record live host and child PIDs, install the verified new app, and trigger a normal GUI quit/reopen.
- [ ] Verify all eleven live PIDs and tab reconnections, plus the separate version 3 host for a fresh tab.

### Task 4: Prepare the distributable 0.1.11 release

**Files:** `Sources/PlumKit/Model/AppModel.swift`, `Sources/PlumKit/Terminal/TerminalHost.swift`, `Tests/PlumKitTests/TerminalHostTests.swift`, release artifacts and notes.

- [ ] Verify the published 0.1.10 app's code hash and the update signing key's public key.
- [ ] Remove the current Mac's legacy host PID pin while retaining the published code hash check; verify red and green tests against a live legacy host and a fake socket.
- [ ] Run the full test suite and `scripts/release.sh`; verify bundle code signature, ZIP contents, update signature, version, and SHA-256.
- [ ] Prepare release notes and the Homebrew cask's version and SHA-256 values without publishing.
