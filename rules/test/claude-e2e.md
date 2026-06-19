---
globs: "tests/**,**/*.sh,**/*.Tests.ps1,test_*.py,**/*.spec.*"
---

# Claude Code E2E Testing

When writing tests that spawn `claude -p`, three precautions are required:

1. **Unset `CLAUDECODE`** — Claude Code sets this env var in its session.
   Child processes inherit it, causing `claude -p` to refuse with
   "nested sessions" error. Always `unset CLAUDECODE` before the call.

2. **Use minimal settings.json** — Copying `claude-global/settings.json` into
   the test repo also copies `disableBypassPermissionsMode: disable`, which
   neutralizes `--dangerously-skip-permissions` and causes a hang.
   Write only the hooks needed by the test:
   ```json
   { "hooks": { "PostToolUse": [...] } }
   ```

3. **WSL-via-Windows bridge masks both issues** — When Claude Code on WSL
   runs through the native Windows binary, `CLAUDECODE` is not propagated
   into the WSL shell and user settings are read from the Windows profile.
   Tests that pass on WSL may still fail on macOS native. Always verify
   E2E tests on a true native environment.

## Acceptance Criteria for `claude -p` E2E Tests

- Skip-gate: `[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77` then `"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77` before invoking `claude -p`.
- Skip-gate: `command -v claude >/dev/null 2>&1 || exit 77`.
- Process hygiene: `unset CLAUDECODE` before invocation.
- Fixture hygiene: write `settings.json` with only the hook under test; never include `disableBypassPermissionsMode`.
- Timeout: wrap `claude -p` in `run_with_timeout 180` per [`test/macos-timeout.md`](macos-timeout.md).
- Output capture: prefer `--output-format json` for assertable structure; use `text` only when the assertion is on side-effect files.
- Session ID: pass `--session-id <fixed-uuid>` so the hook's state file is deterministic.
- Frontmatter: file carries `# Tests:` and `# Tags:` in the first 10 lines per `tests/feature-689-frontmatter-convention.sh`.
- `# L3 gap` block: required even on L3 tests when a sibling L2 is the day-to-day runner — document what only a real CI host catches.

## Canonical Template

Reference: `tests/feature-644-agent-delegation/phase5-main-transcript-no-delegated-output.sh` (real `claude -p` E2E currently gated on `RUN_E2E`).

## Hook Audit (in scope for #943)

| Hook | Current L2 | Priority | Rationale |
|---|---|---|---|
| `hooks/workflow-mark.js` | partial (`tests/feature-robust-workflow.sh` lines 1025–1092 embed an E2E case under `RUN_E2E`) | **P1 — extract** | E2E exists but is buried in a 1300-line file; extract to a dedicated `tests/feature-943-workflow-mark-e2e.sh` for focused failure isolation. |
| `hooks/stop-confirm-plan-guard.js` | none | **P1 — add** | Stop-hook sentinel-order validation is unreachable from unit tests; the hook reads the live transcript. |
| `hooks/stop-final-report-guard.js` | extensive (`tests/feature-534-stop-final-report-guard.sh`, 20+ L2 cases) | **P2 — add E2E** | L2 is thorough but cannot exercise the real Stop-event path; one E2E case validates registration. |
| `hooks/session-start.js` | partial (`tests/feature-772-session-start-cleanup-inherit.sh` covers env-file write) | **P2 — add E2E** | env-file write covered at L2; need E2E for actual CONV_LANG injection into a live session. |
| `hooks/subagent-start.js` | none | **P3 — add** | Sub-agent context injection requires a real Task tool call — only reachable via `claude -p`. |
| `hooks/post-compact.js` | none | **P3 — add** | PostCompact event is not reproducible at L2 (requires real compaction trigger). |
| `hooks/supervisor-guard.js` | L2-only (`tests/feature-719-supervisor-guard-hook.sh`, `tests/feature-883-supervisor-guard-wsid.sh`) | **OUT — defer** | Supervisor hang detection has no observable user-facing signal under `claude -p --output-format json`; E2E adds no signal beyond L2. Re-evaluate after #937 phase 2. |

## #943 Priority Order

1. `workflow-mark.js` — extract the existing embedded E2E to a dedicated file.
2. `stop-confirm-plan-guard.js` — write fresh E2E.
3. `stop-final-report-guard.js` — write fresh E2E (paired with existing L2 file; both kept).
4. `session-start.js` — write fresh E2E (paired with `feature-772-session-start-cleanup-inherit.sh`).
5. `subagent-start.js` — write fresh E2E.
6. `post-compact.js` — write fresh E2E.
