# Marker Bypass Contract

Session-scoped markers grant bypass only to the enforcement hooks explicitly listed in
the Honoring-hooks table below. This document defines the cross-hook honoring contract,
the session-ID resolution chain used in the git hook context, and the exit-code
semantics for the pre-commit inline Node snippet.

## Markers

Two marker files live under `getWorkflowDir()` (resolved as `$CLAUDE_WORKFLOW_DIR` if set,
otherwise `~/.claude/projects/workflow/`):

| Marker file | Created by | Scope |
|---|---|---|
| `<sid>.workflow-off` | `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: reason>>` sentinel | See Honoring hooks — bypasses only the hooks marked Yes there |
| `<sid>.worktree-off` | `<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>` sentinel | Bypasses worktree-isolation enforcement only |

`WORKFLOW_OFF` subsumes `WORKTREE_OFF`: when `.workflow-off` is present, all hooks that
check `.worktree-off` treat it as also active.

## Honoring hooks

Inclusion criterion: every `settings.json` `PreToolUse` hook, plus `hooks/pre-commit`.
A hook absent from this table never reads the marker and is never bypassed — the table
is the SSOT (CPR-2); no other document enumerates exceptions independently.

| Hook | Layer | Honors `.workflow-off` | Honors `.worktree-off` |
|---|---|---|---|
| `hooks/enforce-worktree.js` | PreToolUse | Yes | Yes |
| `hooks/block-dotenv.js` | PreToolUse | Yes | No |
| `hooks/block-history-direct.js` | PreToolUse | Yes | No |
| `hooks/block-memory-direct.js` | PreToolUse | Yes | No |
| `hooks/scan-outbound.js` | PreToolUse | **No** | **No** |
| `hooks/block-credentials.js` | PreToolUse | **No** | **No** |
| `hooks/block-shell-config.js` | PreToolUse | **No** | **No** |
| `hooks/block-off-clearance-write.js` | PreToolUse | **No** | **No** |
| `hooks/block-subagent-sentinels.js` | PreToolUse | **No** | **No** |
| `hooks/gate-plan-skip-sentinel.js` | PreToolUse | **No** | **No** |
| `hooks/check-cross-platform.js` | PreToolUse | **No** | **No** |
| `hooks/check-japanese-in-docs.js` | PreToolUse | **No** | **No** |
| `hooks/show-user-verified-context.js` | PreToolUse | **No** | **No** |
| `hooks/confirm-checkpoint.js` | PreToolUse | **No** | **No** |
| `hooks/show-diff.js` | PreToolUse | **No** | **No** |
| `hooks/block-tests-direct.js` | PreToolUse | **No** | **No** |
| `hooks/supervisor-off-proposal-shim.js` | PreToolUse | **No** | **No** |
| `hooks/workflow-gate.js` | PreToolUse | Yes | No |
| `hooks/enforce-issue-close.js` | PreToolUse | Yes | No |
| `hooks/pre-commit` (worktree-isolation gate only) | git pre-commit | Yes | Yes |
| `hooks/enforce-system-ops.js` | PreToolUse | **No** | **No** |

`hooks/pre-commit` honors both markers **only for the worktree-isolation gate** (the
"commits from main worktree are blocked" / "commits to protected branch" guard). The
private-info scanner (`scan-outbound.sh`) that runs later in the same hook is **not**
bypassed by markers — secret leakage protection is unconditional on the git side.
Users who need WORKFLOW_OFF semantics for staged secrets must add the entry to
`.private-info-allowlist`.

`hooks/scan-outbound.js` does not reference the marker at all — its PreToolUse private-info
scan is unconditional, symmetric with the git-side `scan-outbound.sh` above (CPR-5). Users
who need to bypass a specific match must use `.private-info-allowlist` instead.

`hooks/block-history-direct.js`'s marker check runs only after a protected-path hit is
detected, so non-protected paths never pay the session-ID resolution cost.

`hooks/lib/session-markers.js` is the SSOT for marker **reads** and notice strings only
(`isWorkflowOff(sid)` / `isWorktreeOff(sid)` / `workflowOffNoticeText` /
`worktreeOffNoticeText`). Marker file **creation and deletion** are owned by the
workflow sentinel handlers (`hooks/lib/workflow-sentinels.js` and `hooks/workflow-stop.js`),
not by this module.

## Session-ID resolution

All hooks resolve the session ID via `hooks/workflow-state.js#resolveSessionId()`.
See that module for the full priority chain. The git hook context is notable:

- `CLAUDE_ENV_FILE` is propagated by Claude Code to its own process but may or may not
  reach the shell that runs `git commit`. When present, `resolveSessionId()` reads it and
  returns the session ID without JSONL scanning.
- When absent, `resolveSessionId()` falls back to a JSONL scan of
  `~/.claude/projects/<encoded-cwd>/` by modification time.
- That scan now skips any candidate directory (`CLAUDE_PROJECT_DIR`, cwd, realpath) whose
  git common-dir differs from the agents config repo's, so a foreign-repo working directory
  cannot surface another session's transcript id (#1099). The check fails open when git is
  unavailable, preserving headless/CI behavior.

## Multi-session heuristic

When `CLAUDE_ENV_FILE` is absent and multiple Claude Code sessions are concurrently open
on the same project directory, the JSONL scan returns the most recently modified
transcript, which may not match the session that issued `git commit`. This is a known
best-effort limitation. See the Accepted Tradeoffs in the issue #550 intent document for
the rationale for accepting it.

## Exit-code contract (pre-commit inline Node)

| rc | Meaning | Shell action |
|---|---|---|
| 0 | Bypass granted (marker present, sid valid) | `_enforce_skip=1` |
| 2 | No bypass (sid unresolved, no marker, or `AGENTS_CONFIG_DIR` missing) | Enforcement continues |
| 3 | `require()` or thrown error inside try | Warning to stderr; enforcement continues |
| other | Unexpected (e.g. 127 = node not found) | Warning to stderr; enforcement continues |

All error paths fail closed: bypass is granted only when the session ID resolves AND a
marker file exists on disk.
