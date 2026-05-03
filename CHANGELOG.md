### FEATURE: Add CHANGELOG.md — automated via /update-docs (2026-05-04)
Background: update-docs now writes to both docs/history.md (internal) and CHANGELOG.md (user-facing) in one run.
Changes: CHANGELOG.md is now automatically maintained. Each update-docs run appends a user-facing summary entry. doc-append accepts --commits as optional, enabling date-only headers suited for a public changelog.

### FEATURE: Gemini CLI + mmdc integration; draw-mermaid skill; installer flags (2026-05-04)
Background: Gemini CLI and Codex CLI are now optional, installed only with the -Develop flag to keep the default install lightweight.
Changes: New /draw-mermaid skill generates Mermaid diagrams via subagent (dark-mode-safe colors, WCAG 2.1 AA). Workflow flowchart added to README. install.ps1 -Develop / install.sh --develop installs Codex CLI + Gemini CLI + Mermaid CLI (mmdc); default install covers Claude Code only. Gemini API image generation supported via bin/draw-diagram-gemini (paid plan required).
