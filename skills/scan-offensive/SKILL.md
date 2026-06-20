---
name: scan-offensive
description: Retroactively scan a GitHub repo's issues and comments for offensive content and optionally redact matches.
---

# /scan-offensive

Scan a GitHub repository's issues and comments for offensive content
(hate speech, slurs, harassment, profanity) using `bin/scan-offensive`'s
two-tier detector (keyword blocklist + optional LLM borderline classifier).

Companion to the forward filter in `hooks/scan-outbound.js`, which blocks
offensive content at write time. This skill addresses content that
predates the forward filter or was authored outside Claude Code.

## Arguments

| Flag | Default | Meaning |
|---|---|---|
| `<owner>/<repo>` | current repo (`gh repo view`) | Target repository |
| `--dry-run` | on | Report findings only; do not edit |
| `--apply` | off | Redact matches (canary-gated; see Procedure) |
| `--since YYYY-MM-DD` | none | Restrict to issues updated after this date |
| `--limit N` | none | Stop after scanning N issues |
| `--include-private` | off | Also scan private repos (default skips them) |

## Procedure

1. Resolve `<owner>/<repo>` from arguments or `gh repo view --json owner,name`.
2. Invoke `scripts/scan-repo.sh <owner>/<repo> [flags]`.
3. Dry-run mode: show findings to the user.
4. Apply mode: canary — redact the first finding, ask the user to confirm via
   AskUserQuestion, then proceed with remaining findings.

## Non-goals

- Does not scan `gh api` raw calls.
- Does not delete content. Matches are edited to `[redacted by content-scan]`.

## Environment

- `AGENTS_CONFIG_DIR` must be set; `scripts/scan-repo.sh` uses it to locate
  `bin/scan-offensive`.
- `ANTHROPIC_API_KEY` enables the LLM borderline tier; if unset,
  `bin/scan-offensive` falls back to keyword-only with a stderr warning.
