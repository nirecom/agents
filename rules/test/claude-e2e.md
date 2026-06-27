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

