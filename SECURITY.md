# Security

Plum runs shells, deletes git worktrees, reads agent hook messages, and reads the Claude Code login to ask Anthropic for plan usage. Problems in those places matter, and reports are welcome.

## Reporting a problem

Please don't open a public issue for a security problem.

Report it privately with GitHub's form: [Report a vulnerability](https://github.com/YESHYUNGSEOK/plum/security/advisories/new) (the repository's **Security** tab → **Report a vulnerability**).

Say what you found, how to reproduce it, and which version of Plum and macOS you used. You'll get a reply within a week. Once a fix is released, the advisory is published and credits you, unless you'd rather it didn't.

## Supported versions

Only the latest release gets fixes. Plum updates itself, so a fix reaches users through a new release.

## What counts

- Running a command, or reading or writing a file, that the user didn't ask for: through terminal output, a hook or status message, a session file, a repository's contents or names, a downloaded update, or an imported configuration.
- Losing work: a worktree, branch or state file removed or overwritten without the confirmation the app promises.
- The Claude Code or Codex login being stored, logged, or sent anywhere but the provider's own API.
- Another local user, or an unrelated process, driving Plum or its terminal host through their sockets.

## What doesn't

- What a program you run in a terminal does with your own permissions. Plum is a terminal: it runs what you type.
- Agents run with the "skip permission prompts" setting you turned on.
- Builds that are not from this repository's releases.
