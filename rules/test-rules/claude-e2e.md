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
