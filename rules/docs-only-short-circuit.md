# Docs-Only Short-Circuit

When every staged file matches the human-facing docs allowlist, workflow steps 1–6 are auto-bypassed and only `user_verification` is required before committing.

Allowlist:
- Any `.md` file under `docs/`
- Root-level: `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE.md`

Excluded (behavior/prompt code, NOT docs):
- Root `CLAUDE.md`
- Any `SKILL.md`
- Subdirectory `README.md`
