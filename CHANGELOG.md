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

### FEATURE: Workflow: clarify-intent now mechanically enforced before Edit/Write (2026-05-04)
Background: Previously Claude would often skip /clarify-intent at session start despite CLAUDE.md instructions, requiring users to manually redirect to the workflow.
Changes: PreToolUse hook now blocks Edit/Write/MultiEdit/editFiles/NotebookEdit until clarify_intent step is complete or skipped. Read/Grep/Glob/Bash remain available for investigation and skill execution. Skip path: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>". Recovery: echo "<<WORKFLOW_RESET_FROM_clarify_intent>>". TodoWrite checklist creation moved into the clarify-intent skill's Completion section.

### FEATURE: scan-outbound: add warn: prefix for soft-block blocklist patterns (2026-05-04)
Background: Hard-only blocklist made it hard to register suspicious-but-uncertain patterns without false-positive noise.
Changes: Prefix any line in .private-info-blocklist with warn: to mark it as a soft-block pattern. On match, Claude Code asks for user confirmation; interactive git commit prompts y/N via /dev/tty; non-interactive contexts (CI, no TTY) auto-block as a safe default. Hard-block patterns continue to fail immediately and win over warn when both match. Scanner exit code 2 is now reserved for warn-only; the previous usage-error code moved from 2 to 3 (breaking change for any external script that parsed exit 2).

### REFACTOR: blocklist: add warn: examples to .private-info-blocklist.example (2026-05-06)
Background: The .example file is many users' first reference for the blocklist format; without a sample, the new warn: prefix was discoverable only by reading docs/scan-outbound.md.
Changes: Added a commented warn: section to .private-info-blocklist.example with two illustrative patterns and a pointer to the docs section that explains the soft-block UX matrix.
