# Shell Snapshot Repair

Why Bash tool calls on Windows can all exit 127, and how the repo repairs the cause (#2221).

## Problem

Claude Code runs each Bash call by sourcing a shell snapshot under `~/.claude/shell-snapshots/`.
On Windows (Git Bash) a snapshot is occasionally captured while `PATH` is still in Windows form
(`C:\...;C:\...`, `;`-separated). Sourced into bash, that value makes `/usr/bin` unreachable, so
every command in the session exits 127 (command not found) until the snapshot is replaced.

A snapshot in this state is called a **Windows-form snapshot** (glossary: [Windows-form snapshot](../../glossary.md#windows-form-snapshot)).

## Repair

| Layer | Component | Role |
|-------|-----------|------|
| Classify / plan | `hooks/lib/shell-snapshot-path.js` | Pure functions: judge the first `export PATH='...'` line (POSIX, Windows-form, or unrepairable) and plan the POSIX replacement with `/usr/bin` ahead of System32 |
| Locate converter | `hooks/lib/cygpath-locate.js` | Finds Git for Windows' `cygpath.exe` from the Windows side (never via the possibly broken snapshot); other platforms get no converter |
| Rewrite | `hooks/lib/shell-snapshot-repair.js` | Scans the snapshot directory; replaces only the `PATH` line with a compare-and-swap rename (a concurrent writer wins); deletes nothing but its own `*.repair.tmp` |
| Time budget | `hooks/lib/hook-deadline.js` | One shared deadline per hook run; every `cygpath` spawn takes a slice of it |
| Wording | `hooks/lib/shell-snapshot-notice.js` | The `additionalContext` notice text |

Two triggers share that library, both fail-open (never block a tool call, always exit 0):

- **SessionStart** (`hooks/session-start.js`) scans every snapshot and injects `WARNING (shell snapshot): ...` lines into `additionalContext`.
- **PostToolUse / PostToolUseFailure, matcher `Bash`** (`hooks/postuse-shell-snapshot-repair.js`, decision logic in `hooks/postuse-shell-snapshot-repair/session-check.js`). The first Bash call of a session scans once and leaves a per-session marker; afterwards only an `Exit code 127` failure rescans. Only snapshots created since the session began are considered, so other live sessions' files are left to SessionStart. The hook never re-runs the failed command; the notice tells the model to check for side effects before re-running it.

The repair takes effect for the next Bash call. When `cygpath` cannot be found, or the value cannot be converted safely, the snapshot is left alone and the notice says `not rewritten (windows-form, cygpath-unavailable)` or `windows-unrepairable`.

## Recovery when a snapshot stays broken

1. Restart Claude Code so it takes a fresh snapshot.
2. Run `/sweep-shell-snapshots --dry-run` to list stale snapshots; it only considers files older than 1440 minutes and never repairs the current session's own snapshot ([skills/sweep-shell-snapshots/SKILL.md](../../../skills/sweep-shell-snapshots/SKILL.md)).

`bin/shell-snapshot-path-classify.js -- <file>...` prints `<verdict>\t<file>` per snapshot (read-only); `bin/sweep-shell-snapshots.sh` calls it once per run to label candidates `windows-form` / `windows-unrepairable`.

## Related: gh on Windows

`gh.exe` is a native Windows program and does not understand MSYS paths such as `/tmp/...`. Scripts run it under `MSYS_NO_PATHCONV=1`, so `bin/lib/native-path.sh` `native_path` converts the `--body-file` / `--input` argument with `cygpath -m` at the gh call site (`-` and non-MSYS hosts pass through unchanged).

## Hook registration

Both events are registered in `settings.json` (timeout 5 s, equal to `HOOK_TIMEOUT_MS`); see [settings/hooks.md](settings/hooks.md). The hook reads no bypass marker: [marker-bypass-contract.md](marker-bypass-contract.md).
