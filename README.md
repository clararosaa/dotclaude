# dotclaude

The parts of a Claude Code setup in `~/.claude` that are worth sharing: the global `CLAUDE.md`,
`settings.json`, the hooks, workflows and agents, and the `pull-requests` skill.

## Use it on a new machine

```bash
git clone <this repository> ~/Projects/dotclaude
~/Projects/dotclaude/sync.sh --install
```

`--install` copies the files into `~/.claude` and keeps any existing file that differs as
`<name>.bak`. Restart Claude Code afterwards so the hooks load.

## Keep it in step

`sync.sh` pulls this checkout, then reconciles every mirrored file: a change that came from the
pull is installed into `~/.claude`, a change made in `~/.claude` is copied here, and a file
changed on both sides stops the run for a manual merge. It then scans everything that would be
published for the local user name, home paths, the git identity, email addresses and
credential-shaped strings, and prints `git status`.

`sync.sh --commit <message file> [path...]` does the same, then commits and pushes.

## Optional files

- `sync-allow.txt`: literals the scan lets through, one per line.
- `sync-deny.txt` (git-ignored): literals that always fail the scan and commit messages.
- `sync-mirrors.txt` (git-ignored): directories that get a copy of every published file. With
  `--commit`, each one is committed and pushed with the same message and a line naming the
  commit here.
