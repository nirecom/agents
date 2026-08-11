---
name: sweep-issues
description: Triages open GitHub issues. Closes finished meta parents by default; --deep adds human-gated tier-2 triage.
user-invocable: true
model: sonnet
---

Sweeps the open-issue backlog.

- tier 1 — meta parents whose sub-issues are all closed. Closed on every run.
- tier 2 — issues whose referenced `tests/*.sh` paths no longer exist. Listed on every run; closed only under `--deep`, one at a time with the user's approval.

The user types at most `--deep` and `--dry-run`. Passes 2 and 3 are this skill's own calls (SI-5, SI-7) — the user never supplies a TSV path.

## Procedure

Read `rules/github-issues.md` before SI-1 — on-demand-only, never auto-injected; it owns the close paths, the `status:migrated` / `status:cancelled` labels, and meta-parent handling.

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
- `--deep` never changes the write mode, and never widens the candidate set — SI-2 scans identically with and without it. It decides only whether the tier-2 candidates reach the human gate or are dropped after being listed.
- `--verify-candidates` / `--decisions` are this skill's protocol with the script, not user flags. Never surface them in a suggestion to the user; never expect the user to pass one.
- Pass `--deep` on every tier-2 call (SI-5 and SI-7); omitting it exits 2.
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
