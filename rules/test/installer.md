---
paths:
  - "install/**"
  - "**/*.Tests.ps1"
---

# Installer Testing

Silent installers (NSIS, Electron-builder, etc.) have non-obvious behaviors that tests must account for:

- **Async completion**: Installers often spawn child processes and return immediately. `Start-Process -Wait` only waits for the parent. Poll for expected artifacts with a timeout instead of trusting process exit.
- **Variable install paths**: Per-user vs per-machine installs use different directories (e.g., `%LOCALAPPDATA%\Programs\` vs `%ProgramFiles%\`). Always check all candidate paths rather than hardcoding one.
- **Silent failure**: Exit code 0 does not guarantee success. Flag combinations that work interactively may silently fail in silent mode (e.g., `/S /currentuser`). Always verify the actual installed artifact exists.
- **Idempotency**: Re-installing doesn't fail or leave inconsistent artifacts. PATH/env additions don't duplicate on re-run. Version-pinned installs produce the same result.
