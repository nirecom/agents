# Session Sync

Syncs Claude Code session history (`~/.claude/projects/`) across multiple machines
(Windows, macOS, Linux).

**Problem**: Claude Code indexes projects by absolute path (e.g.,
`C:\Users\<user>\git\repo` → `~/.claude/projects/-C-Users-<user>-git-repo/`).
Paths containing the username differ across machines, making session reference and
resume impossible.

**Solution**: Use drive-root unified paths to eliminate username dependency,
and sync history via a private GitHub repo.

| Path | Purpose |
|---|---|
| (drive-root LLM dir) | LLM infrastructure (immovable — tightly coupled with NSSM services, TLS certs, GGUF model paths) |
| (drive-root git dir) | All other git repositories (Windows) |

**Sync method**: Initialize `~/.claude/projects/` as a git repo, syncing to
`nirecom/agent-sessions` (private). Init fetches existing remote history
(`fetch` + `reset`) before first commit so that 2nd+ machines inherit prior
session data without conflict.

| File | Repository | Responsibility |
|---|---|---|
| [install/win/session-sync-init.ps1](https://github.com/nirecom/agents/blob/main/install/win/session-sync-init.ps1) | agents | Initialization — Windows |
| [install/linux/session-sync-init.sh](https://github.com/nirecom/agents/blob/main/install/linux/session-sync-init.sh) | agents | Initialization — Linux/macOS |
| [bin/session-sync.ps1](https://github.com/nirecom/agents/blob/main/bin/session-sync.ps1) | agents | Daily operation — Windows |
| [bin/session-sync.sh](https://github.com/nirecom/agents/blob/main/bin/session-sync.sh) | agents | Daily operation — Linux/macOS |
| [.env.example](https://github.com/nirecom/agents/blob/main/.env.example) | agents | Remote URL config template (copy to `.env`) |

**Configuration** (`agents/.env`, gitignored):

```
SESSION_SYNC=off
SESSION_SYNC_REMOTE_URL=git@github.com:YOUR_USERNAME/agent-sessions.git
```

`SESSION_SYNC` accepts `on` / `off` only; everything else (unset, empty, `yes`/`true`/`1`,
config-read failure, node missing) falls back to `off` — fail-safe OFF, the opposite
direction from `RUN_TL3`'s fail-safe-ON convention.

Sibling mechanism: [plan-sync](plan-sync.md) publishes final plan files to its own
private remote (`PLAN_SYNC_REMOTE_URL`, same URL format) at write time.

Priority at init time: `--remote-url` CLI arg > `.env` > built-in default.
Changing `.env` after init requires re-running `session-sync-init.sh` / `session-sync-init.ps1`.

## Init-time trust boundary

The initializers accept a remote URL from configuration and, when an earlier install
left a git root directly in `~/.claude/`, move that repository down into
`~/.claude/projects/`. Both are privileged acts on untrusted input: a crafted URL is
code execution (git's `ext::`/`fd::` remote helpers run a shell), and a
provenance-free move is silent data loss. Three gates therefore run, in this order,
**before any filesystem write** — a refusal must leave the machine byte-identical,
including no freshly created `projects/` directory.

**1. Remote-URL allowlist.** Only `https://`, `ssh://`, `git://` with a syntactically
valid host, and the SCP-like `user@host:path` form are accepted. Everything else is
refused and the run aborts: local paths and `file://`, remote-helper schemes
(`ext::`, `fd::`), other schemes (`http://`, `ftp://`), malformed authorities, and
any value starting with `-` (option injection into the `git remote` command line).
The pattern is written in POSIX ERE so that the bash and PowerShell ports stay
literally identical; `tests/fixtures/session-sync-remote-url-patterns.txt` is the
shared contract both implementations are checked against. On refusal an existing
`origin` is left untouched — a bad config cannot repoint a working install.
Credentials embedded in an accepted URL are redacted (`user:***@host`) in all output.

**2. Path containment.** `$CLAUDE_DIR` and `$PROJECTS_DIR` are resolved to real paths
(symlinks, junctions and `..` fully expanded) by `_resolve_realpath` /
`Resolve-RealPath`, then checked in two stages: the resolved claude dir must lie
inside the resolved `$HOME` (equal to `$HOME` is allowed), and the resolved projects
dir must lie strictly inside **the resolved claude dir** — not merely inside `$HOME`.
Checking only against `$HOME` was a real bypass: a `projects` symlink pointing at an
unrelated repo elsewhere under `$HOME` would have passed. Resolving to the same path
as the claude dir is also refused. Comparison is separator-aware, so a sibling whose
name merely shares the prefix (`<home>-evil`) is outside.

**3. Migration provenance.** Evaluated only when `~/.claude/.git` exists — a fresh
install never sees it. The installer asks: is the repository about to be moved the
one this configuration is for? The expected origin is taken from, in priority order:

| # | Source | Notes |
|---|---|---|
| 1 | `--expected-origin` / `-ExpectedOrigin` | Explicit operator intent; outranks everything, including a conflicting `--remote-url` |
| 2 | the resolved, allowlist-validated remote URL (`--remote-url` / `.env` / built-in default) | Skipped entirely under `--no-remote` / `-NoRemote` |
| 3 | — | Nothing to compare against → **refuse** |

The existing repository's `origin` is then read and must match. Absent origin,
mismatched origin, or no expected value at all are all refusals — fail-closed, so an
unrecognized repository is never moved, only reported.

**Migration is transactional.** The pre-#1773 code did an unconditional `rm -rf` of
the destination. It is now a three-phase move (stage the incumbents aside, move the
incoming repository in under temporary names, promote) with rollback on any failure,
and a Phase 0 that aborts if staging names are already present rather than writing
over evidence. Staging uses `.old.<pid>` / `.migrate-tmp.<pid>` suffixes — deliberately
not the repo-wide `.bak` convention, because a `.bak` left in `~/.claude/` is exactly
the git-shaped residue this issue is about; the success path leaves bare final names
only. Renames are judged solely by post-condition (source gone, destination present),
never by the mover's exit code: GNU `mv -n` returns 0 while silently declining a
collision.

**Colliding destination must prove itself too.** Migration only ever promotes
*into* `$PROJECTS_DIR`, so a pre-existing `$PROJECTS_DIR/.git` is itself a
destination the installer cannot trust on sight. The same provenance check from
gate 3 applies to it: its `origin` must be non-empty and match the expected
origin, or the run refuses and leaves both repositories byte-identical. An
origin-less destination used to slip through — non-empty-and-mismatched was
checked, but empty was not — silently promoting an unrelated repository over it.

**Restore after migration is scoped to `projects/`.** The pre-migration root
tracked paths relative to `$CLAUDE_DIR` (typically `projects/<enc>/session.jsonl`
plus a couple of top-level dotfiles). After `.git` moves under `$PROJECTS_DIR`,
`_restore_missing_tracked` / `Restore-MissingTracked` re-checks out any tracked
path `git status` still shows missing — using `$CLAUDE_DIR`, not `$PROJECTS_DIR`,
as the git work-tree, so a path like `projects/<enc>/session.jsonl` lands back at
its real location instead of one level too deep. The restore is pathspec-limited
to `projects/`: top-level tracked files from the old root are deliberately left
alone rather than relocated, since only the `projects/` subtree is user session
data worth preserving across the move.

**Sync scope**:

| Path | Synced | Reason |
|---|---|---|
| `~/.claude/projects/` | Yes | Session history (JSONL) |
| `~/.claude/settings.json` | No | Managed by dotfiles |
| `~/.claude/CLAUDE.md`, `rules/`, `skills/` | No | Managed by dotfiles |
| `~/.claude/statsig/`, `ide/`, `history.jsonl` | No | Machine-specific |

**Line ending control**: `.gitattributes` declares `* text eol=lf`. Preserves LF line endings
in JSONL files generated by Claude Code without conversion.

**Relationship with Web mode**: VS Code's Local/Web toggle provides Web mode (claude.ai/code),
but tasks requiring local filesystem, MCP servers, or NSSM service operations must use Local
mode. Local sessions are invisible to Web and vice versa. Self-hosted sync is necessary for
sharing Local mode session history.

**Automatic sync** — disabled by default. All automatic sync is off unless `.env` carries
an explicit `SESSION_SYNC=on`. The toggle gates 2 systems across 4 call sites:

1. **Shell-startup fetch** — evaluated at shell startup — `profile-snippet.sh` and
   `profile-snippet.ps1`. When on, runs `git fetch + merge --ff-only` on
   `~/.claude/projects/` with a 3-second timeout.
2. **`codes` push** — evaluated at `codes` invocation time — both shells. VS Code always
   opens in a new window (`--new-window`) regardless of the toggle; when on, `codes`
   additionally polls for window closure via title matching
   (`bin/wait-vscode-window.ps1` / `.sh`), then runs session-sync push. Each instance
   independently detects its own window. Push runs in quiet mode: shows a single Windows
   toast notification on completion or failure (WinRT API, no external modules).
   Linux: `notify-send` fallback.

Installer bootstrap (`install.sh` / `install.ps1` calling `session-sync-init.sh` /
`.ps1`) is **not** one of the gated systems — it runs unconditionally whenever the
`claude` CLI is present, regardless of `SESSION_SYNC`. It is a one-time idempotent setup
step (git init, `.gitattributes`/`.gitignore` write, remote add/set-url) with no ongoing
automatic-sync side effects, so leaving it ungated is safe. This is what makes manual
sync (below) always functional right after install, independent of the toggle's value.

**Manual sync**:
```
End of work:    Close all Claude Code sessions → session-sync push
Other machine:  session-sync pull → Launch Claude Code
```
Manual invocation of `session-sync push/pull/status/reset` is never gated by
`SESSION_SYNC` — it always runs regardless of the toggle's value. This guarantee holds
only because installer bootstrap (above) always runs: without it, a fresh install with
the default (off) toggle would leave `~/.claude/projects/` uninitialized as a git repo,
and manual commands would fail.

**Known behavior**: before the engine below, `session-sync push` used `git add .` to stage all
working tree changes. In 2026-04, a format migration (`UUID.jsonl` → `UUID/subagents/`) caused 35
files to be bulk-deleted; most had directory versions with no data loss. One-time event.

## Sync engine (#2658)

`push`, `pull`, `reset`, the shell-startup fetch and `restore-mtime` all call one node engine,
`bin/session-sync-engine`, with its modules in `bin/lib/session-sync/`; `session-sync.{sh,ps1}`
keep only argument handling, the toggle check and notifications.

**Why**: the old `fetch` + `rebase` / `merge` flow left a half-finished rebase on machines that
sync rarely, and every later run failed until `session-sync reset`. The engine never enters a
rebase or merge, so that state cannot arise.

**Integration**: each run builds a commit from the remote tip's tree, re-adds files that exist
only locally, and merges a transcript present on both sides line by line (union, file order kept;
lines without a uuid compare as whole lines). History stays fast-forward. A non-fast-forward
push rebuilds from the new remote tip and retries up to 3 times. Concurrent runs are serialised
by a lock; a run that finds a leftover rebase or merge state discards it, keeping the working
tree, which also migrates already-stuck machines.

**Non-jsonl files changed on both sides** keep the newer one by mtime; edits within a 120 s
clock-skew window keep both, the loser as a `.sync-conflict-<host>-<time>` sibling. A transcript
line whose uuid matches on both sides but whose content differs keeps one version in place and
moves the other into the same kind of sibling, also when a stuck clone is recovered. Pulled
transcripts get their last entry's timestamp as mtime so that session lists sort correctly.

**File/directory collisions** (one side has `a`, the other `a/x`): the directory wins and the
file is kept as `a.sync-conflict-<blob12>`. When that name is already taken by another blob or a
directory, the copy takes `-2`, `-3`, …; a numbered copy that already holds the same blob is
reused, so repeated syncs converge instead of adding copies.

**Timeouts**: a git child that overruns is killed with its process tree (`taskkill /T` on
Windows, waited for at most 5 s), so the lock is always released.

**Excluded from sync**: `workflow/`, `*.tmp`, `*.bak.*`, temp directories and `plans/*` other than
`*.md` (SSOT `bin/lib/session-sync/exclude.js`). Already-tracked excluded files leave the index
and the remote but stay on disk. Plans (`*.md`) travel in both directions on push and pull; a local
plan edited since the last sync is never overwritten.

**Shell-startup fetch**: runs in the background and never blocks the shell. Its deadline is
`SESSION_SYNC_STARTUP_DEADLINE_MS` in `.env` (default 3000; empty, non-numeric, 0 or negative
fall back to 3000; above 60000 is clamped to 60000), so a slow machine is tuned without a release.

**Known limits** (accepted at review): a transcript line present only in the last-synced commit
but absent from the working tree is not restored; an append can join a line Claude Code is still
writing; a whole-file write deferred because the file changed mid-sync can lose the remote
version on the next run; a non-jsonl real rebase conflict keeps the local version only inside the
marker-bearing sibling; a failed or timed-out `taskkill` is not checked, so a grandchild can
outlive the run; an old unsorted `history.jsonl` keeps its file order until a merge adds a line;
deleting `.gitignore` in an unpushed local commit also deletes it on the remote (the managed
block rewrites it locally).

**Symlink structure** (managed by `install/{linux,win}/dotfileslink.{sh,ps1}`):
- `CLAUDE.md` → `~/.claude/CLAUDE.md`
- `settings.json` → `~/.claude/settings.json`
- `skills/` → `~/.claude/skills/`
- `rules/` → `~/.claude/rules/`
- `agents/` → `~/.claude/agents/`

## Plans directory resolution

`bin/session-sync.{sh,ps1}` copies session planning artifacts (intent/outline/detail `.md` files) between the local machine and the sync repository. The local directory is resolved via `bin/workflow-plans-dir`, which honours the `WORKFLOW_PLANS_DIR` env var (default: `~/.workflow-plans/`). The transport directory on the sync mount is always `plans/` and is not affected by this setting.

The copy-based transport (not symlink/bind-mount) is intentional — symlinks
into `~/.claude/` would trigger Claude Code's protected-path ask dialog
(precedent: PR #256 / history 2026-05-14), and a bind-mount/junction would
tie session-sync to OS-specific filesystem features. Skill orchestrator, JS
hooks, and `session-sync.{sh,ps1}` all resolve via the same helper
(`bin/workflow-plans-dir`); skill prompts reach the helper through the
orchestrator-injects protocol documented in
`skills/_shared/resolve-plans-dir.md`.
