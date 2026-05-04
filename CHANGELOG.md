### FEATURE: Add CHANGELOG.md — automated via /update-docs (2026-05-04)
Background: update-docs now writes to both docs/history.md (internal) and CHANGELOG.md (user-facing) in one run.
Changes: CHANGELOG.md is now automatically maintained. Each update-docs run appends a user-facing summary entry. doc-append accepts --commits as optional, enabling date-only headers suited for a public changelog.

### FEATURE: Gemini CLI + mmdc integration; draw-mermaid skill; installer flags (2026-05-04)
Background: Gemini CLI and Codex CLI are now optional, installed only with the -Develop flag to keep the default install lightweight.
Changes: New /draw-mermaid skill generates Mermaid diagrams via subagent (dark-mode-safe colors, WCAG 2.1 AA). Workflow flowchart added to README. install.ps1 -Develop / install.sh --develop installs Codex CLI + Gemini CLI + Mermaid CLI (mmdc); default install covers Claude Code only. Gemini API image generation supported via bin/draw-diagram-gemini (paid plan required).

### SECURITY: Strengthen settings.json deny rules; add security-policy.md (2026-05-04)
Background: Push deny rules had coverage gaps.
Changes: Deny rules now cover additional push flag variants. New docs/security-policy.md documents the permission model. README updated to highlight deny-list as a security feature.

### SECURITY: Block Claude Code writes to .private-info-allowlist (2026-05-04)
Background: In VSCode ask-before-edits mode, permissions.deny rules for Edit/Write are bypassed, so CC could silently append exceptions to the scan-outbound allowlist.
Changes: The block-dotenv.js PreToolUse hook now blocks all Edit/Write access to .private-info-allowlist. Exceptions must be added manually.
