---
globs: "**/.env.example,**/.env.sample,**/.env.template,**/.env.dist"
---

## .env.example Rules

End-user configuration documentation. For each variable, the comment block must cover **only** these three things, written from the user's perspective:
1. **What you can do** with this setting (the user-visible effect).
2. **What you can't do** (limits, what is NOT changed by this setting).
3. **Format** — value syntax, supported pattern features, and at least one example per supported platform.

## Size cap

Each variable's comment block must be 1–5 lines (excluding the `VAR=value` line itself).

## Prohibited content

1. No `# VARNAME — description` heading lines that repeat the variable name.
2. No issue-number references (`#NNN`, `(#NNN)`, `issue #NNN`).
3. No internal implementation-detail references: file paths matching `hooks/*.js`, `bin/*`, `skills/*`; bare `*.js` filenames; hook event names (`PreToolUse`, `PostToolUse`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `SessionStart`); protocol terms (`orchestrator-injects`, `resolve-plans-dir`).
4. No redundant `# Example: VAR=…` lines.
5. No architecture/implementation-rationale explanations (why the system is designed a certain way — belongs in `docs/architecture.md` or `history.md`).
6. No related-command references (instructions to run a command — belongs in `README.md` or `docs/ops.md`).

## Category headings

Group related variables into `# --- <Category name> ---` heading comments. Consecutive members of a category must be contiguous.

## Enforcement

Checked by `bin/review-env-example` (HARD = regex-decidable; WARN = judgment-required). Target globs and detection patterns are hardcoded in the script. Update both files in the same diff.

## Judgment note

Architecture-rationale and command-reference detection is necessarily incomplete (WARN, not HARD). Apply human judgment on WARN output.
