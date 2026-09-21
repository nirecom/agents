---
name: review-docs
description: Verify staged doc changes satisfy line-limit and README section-order gates before commit; symmetric to review-code-security.
model: sonnet
effort: high
---

Verify that documentation changed in this session satisfies the doc conciseness gates before the commit gate enforces them. Symmetric to `/review-code-security`: an evidence-bound review step gated on the staged blobs, not on recorded status.

## When to Use

Use after `/update-docs`, once doc/changelog edits are staged, before commit.

## Rules

- The commit gate re-runs `bin/review-doc-gates --staged` on every commit (TOCTOU-safe); a passing review now does not exempt a later staged edit.
- Line limits: SSOT is `rules/coding/file-split.md` Pattern C (WARN 300, HARD 500). History/archive/CHANGELOG files are exempt.
- README section order: SSOT is the parseable block in `rules/docs/readme.md`.
- Fix every HARD (blocking) failure before emitting the completion sentinel; WARN findings are advisory.

## Procedure

RD-1. Run `bash "$AGENTS_CONFIG_DIR/bin/review-doc-gates" --all` for an advisory full-tree scan of size and heading-order issues.
RD-2. Run `bash "$AGENTS_CONFIG_DIR/bin/review-doc-gates" --staged` to see exactly what the commit gate will block; exit 1 means a staged doc violates a HARD limit.
RD-3. Fix each HARD failure — split an oversized file per Pattern A/C, or reorder README sections per the SSOT block — then re-run RD-2 until it exits 0.

## Completion

Emit only after RD-2 exits 0 (or nothing doc-related is staged, in which case the gate self-skips). As a standalone Bash call: `echo "<<WORKFLOW_MARK_STEP_review_docs_complete>>"`.

If a doc review genuinely does not apply (no staged doc changes and none intended), skip instead: `echo "<<WORKFLOW_REVIEW_DOCS_NOT_NEEDED: reason>>"` (reason mandatory, >=3 non-space chars, no `>`).

## Relationship to Other Tools

- `/update-docs` — writes the docs and changelog this step reviews (run first).
- `bin/review-doc-gates` — the size + heading-order aggregate this step and the commit gate both call (CPR-SSOT).
