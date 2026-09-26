# Group 09 — Existing tests whose expectations must be REVERSED by the #1133/#1148 fix

This is a **note**, not an executable test. When the approval-gate fix lands, the
tests below currently assert the *pre-fix* (buggy) behavior — evidence-only
auto-completion of `outline`/`detail`, and the pre-fix inconsistency-scan
ordering. Each listed case must be updated in the *same* change that implements
the fix, or it will produce a false-red (blocking a correct fix) or, worse, lock
in the bug.

The reversals are intentionally NOT made here: this WT step writes new
regression coverage only. The implementer owns editing the existing suites.

## `tests/fix-1133-next-step-mark-outline-detail/` (sourced by `tests/fix-1133-next-step-mark-outline-detail.sh`)

- `auto-repair.sh`
  - Cases asserting `outline`/`detail` auto-complete purely from `*-outline.md` /
    `*-detail.md` presence must now assert **not-complete without a recorded
    approval**. The "review-not-started" / "review-done" evidence fixtures no
    longer justify completion on their own.
- `mark.sh` (M1, M1b) and `idempotency-security.sh` (I1a–I1d)
  - `--mark outline complete` / `--mark detail complete` currently expect exit 0
    and `status=complete`. Post-fix these must expect **nonzero exit and
    unchanged status** unless a `plan_approvals` record exists first (see G12).
    Idempotency cases need an approval seeded in the fixture to keep exit 0.
- `hint.sh`
  - Hints that steer the user to `--mark outline complete` as the recovery for a
    compaction gap must be re-checked: post-fix the recovery path also requires
    an approval (or a sanctioned reset), so hint text / expectations may change.
- `reconcile.sh` (G1c/G1d)
  - `reconcile-state --dry-run` currently expects `outline`/`detail` to show a
    `pending -> complete` transition from artifact presence alone. Post-fix
    reconcile must **not** propose completing a gated step without an approval;
    the expected dry-run line changes accordingly.

## `tests/bin-workflow-next-step/transitions.sh`

- Any transition case that walks `outline`/`detail` from `pending` to `complete`
  via evidence/auto-repair must seed a `plan_approvals` entry (or set
  `CONFIRM_OUTLINE=off` / `CONFIRM_DETAIL=off`) to remain valid. Cases that do
  not, and expect completion, must flip to expecting the step to stay pending.

## `tests/feature-1094-next-step-docs-evidence.sh`

- ODE-1 / ODE-2 / ODE-3 concern the non-gated `docs` step and remain valid as-is.
- They must keep passing after the #1148 ordering change (docs evidence resolved
  via the read-only effective-state snapshot before the inconsistency scan).
  Re-run them as a guard; no expectation reversal is expected, only confirmation
  that the reorder did not regress docs auto-complete.
