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
| `<sid>.worktree-off` | `<<WORKFLOW_ENFORCE_WORKTREE_OFF: reason>>` sentinel | See Honoring hooks — bypasses only the hooks marked Yes there |

`WORKFLOW_OFF` subsumes `WORKTREE_OFF`: when `.workflow-off` is present, all hooks that
check `.worktree-off` treat it as also active.

## Honoring hooks

Inclusion criterion: every hook that calls `isWorkflowOff` / `isWorktreeOff` from
`hooks/lib/session-markers.js`, plus `hooks/pre-commit` (which reimplements the same
check inline for the git context — see Session-ID resolution below). This is a
grep-derivable criterion (`grep -rl "isWorkflowOff\|isWorktreeOff" hooks/`), not an
enumerated guess: a hook absent from this table does not call either function and is
never bypassed. This table is the SSOT (CPR-SSOT); no other document enumerates
exceptions independently.
Since #2037 removed the curated excerpt that `rules/workflow-off.md` used to carry, this
table is not merely canonical but the **only** enumeration that exists — a rule file
answering "which hooks does my marker bypass?" links here rather than restating a subset.

| Hook | Layer | Honors `.workflow-off` | Honors `.worktree-off` |
|---|---|---|---|
| `hooks/enforce-worktree.js` | PreToolUse | Yes | Yes |
| `hooks/block-dotenv.js` | PreToolUse | Yes | No |
| `hooks/block-history-direct.js` | PreToolUse | Yes | No |
| `hooks/block-memory-direct.js` | PreToolUse | Yes | No |
| `hooks/scan-outbound.js` | PreToolUse | **No** | **No** |
| `hooks/block-credentials.js` | PreToolUse | **No** | **No** |
| `hooks/block-shell-config.js` | PreToolUse | **No** | **No** |
| `hooks/block-clearance-token-write.js` | PreToolUse | **No** | **No** |
| `hooks/block-subagent-sentinels.js` | PreToolUse | **No** | **No** |
| `hooks/gate-plan-skip-sentinel.js` | PreToolUse | **No** | **No** |
| `hooks/check-cross-platform.js` | PreToolUse | **No** | **No** |
| `hooks/check-japanese-in-docs.js` | PreToolUse | **No** | **No** |
| `hooks/show-user-verified-context.js` | PreToolUse | **No** | **No** |
| `hooks/confirm-checkpoint.js` | PreToolUse | **No** | **No** |
| `hooks/show-diff.js` | PreToolUse | **No** | **No** |
| `hooks/block-tests-direct.js` | PreToolUse | **No** | **No** |
| `hooks/supervisor-off-proposal-shim.js` | PreToolUse | Yes | Yes (only when the OFF proposal's target is `worktree`) |
| `hooks/workflow-gate.js` | PreToolUse | Yes | Yes (skips the unstaged-tracked Gate 1 check AND makes the Tier 3 worktree-entry early gate return `verdict: "dormant"`) |
| `hooks/enforce-issue-close.js` | PreToolUse | Yes | No |
| `hooks/confirm-forge-target-ownership.js` | PreToolUse | No | No |
| `hooks/stop-premature-stop-guard.js` | Stop | Yes | No |
| `hooks/stop-final-report-guard.js` | Stop | Yes | No |
| `hooks/stop-l2-findings-display.js` | Stop | Yes | No |
| `hooks/supervisor-guard.js` | Stop | Yes | No |
| `hooks/supervisor-trigger.js` | PostToolUse | Yes | No |
| `hooks/pre-commit` (worktree-isolation gate + prompt-extraction backstop) | git pre-commit | Yes | Yes |
| `hooks/enforce-system-ops.js` | PreToolUse | **No** | **No** |
| `hooks/block-comment-block-size.js` | PreToolUse | **No** | **No** |
| `hooks/postuse-step-in-flight-mark.js` | PostToolUse | **No** | **No** |
| `hooks/user-prompt-submit-mechanism-check.js` | UserPromptSubmit | **No** | **No** |

`hooks/pre-commit` honors both markers for **two separate sections**: the worktree-isolation
gate ("commits from main worktree are blocked" / "commits to protected branch" guard) and
the prompt-extraction backstop (`bin/check-prompt-extraction --staged` runner added in
issue #1642). Both sections check the same markers via the shared `_session_marker_off()`
function. The permanent escape hatch for the prompt-extraction backstop is the committed
`.prompt-extraction-allowlist` file; the session markers are for emergency bypass only.

Note that prompt-extraction violations are a reversible quality concern, not secret leakage,
which is why markers bypass the backstop here (unlike `scan-outbound.sh` which is
unconditional — secret leakage is irreversible). Users needing permanent per-file exemptions
should use `.prompt-extraction-allowlist` instead of session markers.

The private-info scanner (`scan-outbound.sh`) that runs later in the same hook is **not**
bypassed by markers — secret leakage protection is unconditional on the git side.
Users who need WORKFLOW_OFF semantics for staged secrets must add the entry to
`.private-info-allowlist`.

`hooks/postuse-step-in-flight-mark.js` and `hooks/user-prompt-submit-mechanism-check.js`
(#2013 / #1979) read no marker at all. Neither one enforces anything: the first records the
current step `in_progress` when a dispatch tool runs, the second reports a stalled step at
the next user turn. There is nothing for a session override to suspend, so they are listed
**No/No** rather than left out of the table (CPR-ORTH — absence would be indistinguishable
from an oversight). The `.stall-reported` ledger they write is protected state, not a
bypass: see `hooks/lib/protected-basenames.js`.

`hooks/scan-outbound.js` does not reference the marker at all — its PreToolUse private-info
scan is unconditional, symmetric with the git-side `scan-outbound.sh` above (CPR-ORTH). Users
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
