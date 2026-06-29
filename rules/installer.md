---
globs: install/**,**/*.ps1,**/*.nsi,**/*.iss
---

# Installer & System Configuration

## System Configuration Principles

- **System stability is the top priority.** Do not pollute the registry with unverified entries.
- **Do not force external configuration** — even if the user requests it:
  - Registry-based flag injection must be verified to actually work before writing. If the app ignores externally written entries (e.g., encrypted config, internal state mismatch), abandon the approach rather than leave dead entries.
  - Never patch binary or encrypted config files to inject settings. (Precedent: Google Japanese Input config.)
- **Clean up mistakes immediately.** If a registry entry turns out to be ineffective, delete it before proceeding with any other fix.

## System-Wide Package Managers

System-wide package install/uninstall/upgrade requires explicit user approval (Rule 2 of
`rules/user-escalation.md`). The `hooks/enforce-system-ops.js` PreToolUse hook enforces
this — see the hook source for the exact command set. Per-repo and user-scope variants
(e.g. `npm install` without `-g`) pass through.

Legitimate installer scripts under `install/` have a controlled bypass; see those scripts
for the mechanism. The protection is structural (inherited env only), so model-issued
inline forms cannot bypass.

## Winget Install

- Always check `$LASTEXITCODE` after `winget install` and report failure with exit code and re-run guidance
