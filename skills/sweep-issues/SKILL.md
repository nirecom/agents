---
name: sweep-issues
description: Triages open GitHub issues. Closes finished meta parents by default; --deep adds human-gated tier-2 triage.
user-invocable: true
model: sonnet
---

Sweeps the open-issue backlog. A flagless run closes tier-1 candidates and reports tier-2 candidates; `--dry-run` writes nothing.

## Procedure

SI-1. Run `bash "$AGENTS_CONFIG_DIR/bin/sweep-issues.sh"` forwarding the user's flags verbatim (pass 1).
SI-2. Print stdout verbatim. Do not summarize or filter.
SI-3. Stop here when the output carries no `<<<TIER2-GATE-SI3` block.
SI-4. With the block: use `AskUserQuestion` to separate false positives (artifact not built yet) from real staleness.
   Write the survivors to `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-sweep-issues-survivors.tsv`.
   Columns: `number` / `tokens_csv` / `class`. Copy columns 1-2 from the gate template rows.
   `class` ∈ `resolved` | `refactored-away` | `duplicate` | `obsolete` | `partial`.
SI-5. Re-run with `--verify-candidates <survivors.tsv> --deep` (pass 2) and print every `EVIDENCE-` line verbatim.
SI-6. Present the `<<<TIER2-GATE-SI5` candidates plus their evidence in one batched `AskUserQuestion`.
   Write only the approved rows to `<session-id>-sweep-issues-decisions.tsv`.
   Columns: `number` / `action` / `arg` / `rationale`. `arg` is the surviving issue for `migrated`, else `-`.
SI-7. Emit `<<WORKFLOW_ISSUE_CLOSE_VERIFIED: sweep-issues batch triage>>`, re-run with `--decisions <decisions.tsv> --deep` (pass 3), then emit `<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: sweep-issues batch triage done>>`.
   Report every `PARTIAL:` line verbatim.

## Rules

- Applies by default; `--dry-run` suppresses tier-1 closes too.
- `--deep` never changes the write mode — it changes candidate scope and human gating only.
- Pass `--deep` on every tier-2 call (pass 2 and pass 3); omitting it exits 2.
- The flagless run is non-interactive. Never place `AskUserQuestion` on the default path.
- Pair `--deep` with a small band (e.g. `--band-size 20`) — SI-5 runs real tests and large bands do not finish in usable time.
- Under `--dry-run`, SI-5 reports the test it would run instead of running it; running a repository script is an effect.
- A pass-1 run exits non-zero when any sub-step failed. Treat a non-zero exit as "this band was not swept", never as "nothing to do".
- `--repo` must name the working tree's own repository; pass `--repo-root DIR` when sweeping a repository checked out elsewhere, or the run aborts.
- Close only through the existing helpers. Never call `gh issue close` directly.
- The judgement axis table's SSOT is the header of `bin/sweep-issues/close-batch.sh`; it is not restated here.
- SI-5 evidence never rests on the issue body's own claims.
- Write both intermediate TSVs outside the repo, under `${WORKFLOW_PLANS_DIR}` — in-repo writes are blocked by `enforce-worktree.js`.
- After a run that closed several tier-1 children of one parent, recommend `/issue-reconcile`: `parent-body-update.sh` can lose an update between concurrent closes.
- This skill sets no `context: fork`, unlike its sweep siblings, because its human gates need the parent conversation.
