# Importing repositories and worktrees from Orca

2026-11-23. A small change: a short design.

## Intent

Someone moving from Orca to Plum sees the repositories and worktrees they had
in Orca without adding each repository again. It happens once, when they ask
(or accept the offer on a first launch); afterwards Plum and Orca go their own
ways. Plum already lists a repository's git worktrees when the repository is
added; what Orca adds is which repositories, and the names given to worktrees.

## Goals, non-goals

- Goal: Orca's repositories become Plum projects, their worktrees Plum
  workspaces, with Orca's names.
- Non-goals: keeping in step with Orca afterwards; Codex, Superset and other
  apps (later, the same way if they offer a CLI); Orca's archived, pinned and
  linked-issue state; Orca's remote hosts (SSH).
- Anti-goals: writing anything of Orca's; touching anything on disk; an import
  that half works when Orca changes, without saying so.

## Approaches

1. **Orca's CLI (chosen).** `orca repo list --json` and
   `orca worktree list --json --limit 10000`. What Orca shows now, through the
   interface Orca publishes for tools ("Use `--json` when another tool will
   parse the result", its CLI reference). Needs Orca running.
2. Reading Orca's SQLite store (`profile-state.db`). Works with Orca closed,
   but its tables are Orca's internals: a change there breaks Plum silently,
   and the file is being written while read.
3. `orca-data.json`. Not written since July here: stale. Out.

Chosen: 1. For an open-source project the published interface is what a
maintainer can keep working; Orca is MIT, so its behavior can be checked in
its source rather than guessed.

## What the CLI does (Orca 1.4.271 source)

- Orca not running: no launch, no disk reading. stdout is
  `{"ok":false,"error":{"code":"runtime_unavailable","message":…}}`, exit 1.
- `worktree list` returns at most `--limit` rows (default 200, no maximum);
  `truncated` says whether rows were left out.
- A repository's `kind` is `git` or `folder`; missing means `git`.
- A worktree's `branch` is git's own (`refs/heads/foo`); detached is `""`.
- The main checkout is listed (`isMainWorktree`), and so are archived ones
  (`isArchived`). Worktrees of repositories hidden in Orca are not; `repo list`
  shows hidden repositories with `hiddenAt`.
- Nothing promises the JSON's shape or versions it.

## Behavior

- **Where:** a menu item, "Orca에서 가져오기…", always there. On a first launch
  with no projects, if Orca is installed, Plum offers it once.
- **Finding the CLI:** Orca's app by its bundle id (`com.stablyai.orca`, via
  Launch Services), then `Contents/Resources/bin/orca` inside it, run by
  absolute path with fixed arguments and a time limit. Not from `PATH`.
- **Asking:** one confirmation naming the repositories found and how many
  worktrees, then everything is imported (Orca's list is what the user chose
  to add there).
- **Repositories:** those with kind `git` (or none), not hidden, whose folder
  exists and is a git repository. Name: Orca's display name. One Plum already
  has (same path) is kept as it is; only its missing worktrees are added.
- **Worktrees:** not the main checkout, not detached (a Plum workspace is a
  branch), folder exists, not already in Plum (same path). Branch:
  `refs/heads/` taken off. Name: Orca's display name, else the folder's.
  Archived ones are imported like the rest (they are still on disk).
- **Result:** a notice (not an error): repositories and worktrees added, and
  how many were left out and why (detached, missing folder).
- **When it can't:** Orca not running → "Orca를 켠 뒤 다시 시도해 주세요".
  Output that isn't what's expected → nothing imported, and a message saying
  Orca's output wasn't understood, with Orca's version.

## Safety

- Orca's output is input from outside: every path is checked to exist (and be
  a git repository for repositories) before it is used; nothing in it is run.
- Nothing is written outside Plum's own state.

## Checks

- Parsing tested with small made-up samples of the CLI's output: a normal
  list, `ok:false`, a folder repository, a hidden one, the main checkout, a
  detached worktree, `truncated`, a shape Plum doesn't know. No real data.
- Importing tested against a temporary git repository with worktrees.
- Once in the app against the real Orca on this Mac (read-only).

## Left to the builder

The menu's place, the wording of the confirmation and the result, how the
first-launch offer is remembered, and the time limit.
