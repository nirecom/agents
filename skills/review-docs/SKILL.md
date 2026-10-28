---
name: review-docs
description: Verify staged doc changes satisfy line-limit and README section-order gates before commit; symmetric to review-code-security.
model: sonnet
---

Verify that documentation changed in this session satisfies the doc conciseness gates before the commit gate enforces them. Symmetric to `/review-code-security`: an evidence-bound review step gated on the staged blobs, not on recorded status.

## When to Use

Use after `/update-docs`, once doc/changelog edits are staged, before commit.

## Rules

- The commit gate re-runs `bash "$AGENTS_MAIN_ROOT/bin/review-doc-gates" --staged` on every commit (TOCTOU-safe); a passing review now does not exempt a later staged edit.
- Line limits: SSOT is `rules/coding/file-split.md` Pattern C (kind `docs` of its generated Size limits table). History/archive/CHANGELOG files are exempt.
- README section order: SSOT is the parseable block in `rules/docs/readme.md`.
- Glossary entry files: the glossary gate (`bin/review-doc-glossary`) enforces entry form, order and file ranges per `rules/docs/glossary.md`.
- Judge each changed glossary entry's category fit against `rules/docs/glossary.md`, and apply `skills/_shared/combined-glossary.md` (reviewer directives) to the changed docs.
- Fix every HARD (blocking) failure before emitting the completion sentinel; WARN findings are advisory.

## Procedure

RD-1. Run `bash "$AGENTS_MAIN_ROOT/bin/review-doc-gates" --all` for an advisory full-tree scan of size and heading-order issues.
RD-2. Run `bash "$AGENTS_MAIN_ROOT/bin/resolve-session-id"` as a standalone command, then `bash "$AGENTS_MAIN_ROOT/bin/review-doc-gates" --staged --session <its stdout>` to see exactly what the commit gate will block; exit 1 means a staged doc violates a HARD limit or the glossary provenance check blocks.
   When `resolve-session-id` exits 2 (no session), omit `--session`; on any other non-zero exit, HALT and surface its stderr.
RD-3. Fix each HARD failure — split an oversized file per Pattern A/C, or reorder README sections per the SSOT block — then re-run RD-2 until it exits 0.
   With the docs staged, run the `--record` of `skills/_shared/glossary-drift-check.md` with `--stage docs` and resolve its findings there.

## Completion

Emit only after RD-2 exits 0 and the RD-3 glossary drift check leaves no unresolved finding (or nothing doc-related is staged, in which case the gate self-skips). As a standalone Bash call: `echo "<<WORKFLOW_MARK_STEP_review_docs_complete>>"`.

If a doc review genuinely does not apply (no staged doc changes and none intended), skip instead: `echo "<<WORKFLOW_REVIEW_DOCS_NOT_NEEDED: reason>>"` (reason mandatory, >=3 non-space chars, no `>`).

## Relationship to Other Tools

- `/update-docs` — writes the docs and changelog this step reviews (run first).
- `bin/review-doc-gates` — the size + heading-order + glossary aggregate this step and the commit gate both call (CPR-SSOT).
