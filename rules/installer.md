# Installer & System Configuration

## System Configuration Principles

- **System stability is the top priority.** Do not pollute the registry with unverified entries.
- **Do not force external configuration** — even if the user requests it:
  - Registry-based flag injection must be verified to actually work before writing. If the app ignores externally written entries (e.g., encrypted config, internal state mismatch), abandon the approach rather than leave dead entries.
  - Never patch binary or encrypted config files to inject settings. (Precedent: Google Japanese Input config.)
- **Clean up mistakes immediately.** If a registry entry turns out to be ineffective, delete it before proceeding with any other fix.

## Package Manager Commands (System-Wide)

Running any system-wide package manager without explicit user approval is prohibited.
This covers all categories listed in `rules/ops.md` under "System-State-Changing Operations".

**Blocked commands** (require explicit user approval via Rule 2 of `rules/user-escalation.md`):
`winget install/uninstall/upgrade`, `choco install/uninstall`, `scoop install/uninstall`,
`brew install/uninstall/upgrade`, `apt/apt-get install/remove/upgrade`, `npm -g`/`--global`,
`pnpm -g`/`--global`, `yarn global add/remove`, `pip install` (without `--user`),
`python -m pip install` (without `--user`), `pipx install`.

**Not blocked** (query-only):
`winget search`, `apt list`, `brew info`, `npm install` (per-repo), `pip install --user`,
`uv pip install`.

**Installer script bypass:**
Legitimate installer scripts (e.g., `install.ps1`, `install/linux/*.sh`) set
`SYSTEM_OPS_APPROVED=1` before Claude Code launches. This allows the hook to pass.
Inline prefix (`SYSTEM_OPS_APPROVED=1 cmd` in the same Bash call) does NOT bypass the guard
— the hook reads its inherited `process.env`, not the command's inline prefix.

## Winget Install

- Always check `$LASTEXITCODE` after `winget install` and report failure with exit code and re-run guidance
