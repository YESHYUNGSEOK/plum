# Carrying Orca's open Claude and Codex conversations over

2026-11-23. A small change to the Orca import
(`2026-11-23-orca-import-design.md`): a short design.

## Intent

Someone moving from Orca keeps the conversations they had going: where
Orca had Claude or Codex open in a worktree, the imported workspace opens
with that conversation continued in a tab.

## Goals, non-goals

- Goal: one tab per workspace and agent (Claude, Codex) that Orca had open
  there, continuing that folder's most recent conversation, opened as part
  of the import.
- Non-goals: several conversations of one agent in the same folder (only
  the most recent continues); other agents Orca runs; Plum's own agents
  after a restart of the Mac (a separate piece of work).
- Anti-goals: two programs writing one conversation at once; tabs opened
  twice when the import runs again; touching Orca's conversations.

## Approaches

1. **Continue a copy, at import (chosen).** `claude … --continue
   --fork-session` and `codex … fork --last`, both public options. The copy
   has the whole conversation; Orca's stays as it was, and Orca's agent,
   likely still running (the import needs Orca running), never shares a
   file with Plum's. Agents start right away, as they were in Orca.
2. Continue the same conversation (`--continue`, `resume --last`): the
   closest to moving it, but only safe if the user closes Orca's agents
   first; otherwise two programs write one conversation.
3. Continue when the workspace is first opened: no burst of agents, but
   Plum must remember what is still to open, and shows no status until then.

Chosen: 1 (the user's pick).

## Behavior

- **Which:** Orca's `agent list --json` (`result.agents[]`): entries whose
  `agent` is `claude` or `codex`, whatever their `kind`. The folder is the
  part of `worktreeId` after the first `::` (`<repo id>::<path>`).
- **Where:** only workspaces this import added: new worktree workspaces and
  the main checkouts of new projects. A folder Plum already had gets no tab,
  so running the import again opens nothing more.
- **How many:** one tab per workspace and agent, however many Orca had.
- **The command:** Plum's own command for that agent (`AppSettings.command(for:)`,
  with the hooks that report status and the permission flag), then
  ` --continue --fork-session` for Claude, ` fork --last` for Codex. The
  folder is prepared as for any agent tab (trust, Codex hooks).
- **Asking:** the import's confirmation adds how many conversations will be
  continued, when there are any.
- **Result:** the import's notice adds how many conversations were continued.
- **When it can't:** `agent list` failing or unreadable doesn't stop the
  import: projects and workspaces still come in, without the tabs. A folder
  with no conversation for that agent leaves the agent's own message in the
  tab and a shell behind it.

## Safety

`worktreeId` is Orca's output: its path only selects among workspaces the
import has just added (compared by path); nothing from it is run. The
command is built from Plum's own settings and fixed words.

## Checks

- Reading `agent list` with made-up samples: Claude and Codex kept, other
  agents dropped, the path taken from `worktreeId`, one per folder and
  agent, `ok:false` read as nothing to continue.
- Which workspaces get a tab, against a temporary repository: added ones
  only, the main checkout of a new project included, none on a second run.
- The commands for both agents, with and without the permission flag.
- Once in the app against the real Orca on this Mac: the tabs open and the
  conversations continue (Plum's test copy, its own state folder).

## Left to the builder

Where the agent list is read (with the other two lists or after the
confirmation), the order tabs open in, and the exact wording added to the
confirmation and the result.
