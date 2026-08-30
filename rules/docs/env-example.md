---
paths:
  - "**/.env.example"
  - "**/.env.sample"
  - "**/.env.template"
  - "**/.env.dist"
---

## .env.example Rules

End-user configuration documentation. For each variable, the comment block must cover **only** these three things, written from the user's perspective:
1. The user-visible effect, stated directly with no prefix — never write `What you can do:`.
2. `You can't do:` — what this setting does NOT affect. Omit this line when line 1 already makes it obvious.
3. `Format:` — value syntax, at least one example per supported platform, and the "when to use which value" guidance folded into this same line.

## Wording and length

Never wrap one sentence across a continuation line — one sentence per line (HARD).
Never write the `What you can do:` / `What you can't do:` prefix; use `You can't do:` for the negative line (HARD).
Normal block size is 2–3 lines; the HARD 5-line cap below is unchanged.
When two variables form a paired axis of the same decision, write the shared explanation once on the first variable's block only; later variables in the pair carry just their axis-specific difference plus their own `Format:` line.

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

## OS-conditional markers

Lines matching `#@if <os>` or `#@endif` are exempt from all comment-block rules — they are not counted toward the 1–5 line limit and are not checked for prohibited content.
No blank line immediately before `#@endif`: the last content line inside an `#@if` block and the closing `#@endif` must not be separated by a blank line. `bin/review-env-example` detects this as a HARD finding.
When a Windows block and a POSIX block have identical effect and `You can't do:` lines differing only in format examples, write the description once in the Windows block only. The POSIX block contains `VAR=` only (no description lines). This is a WARN-level judgment call, not a HARD check.

## Enforcement

Checked by `bin/review-env-example` (HARD = regex-decidable; WARN = judgment-required). Target globs and detection patterns are hardcoded in the script. Update both files in the same diff.
The legacy `What you can (do|'t do):` prefix and the wrapped continuation line (a comment whose `#` is followed by two or more spaces before content) are both regex-decidable, so each is a HARD check.

## Judgment note

Architecture-rationale and command-reference detection is necessarily incomplete (WARN, not HARD). Apply human judgment on WARN output.
