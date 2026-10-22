# Glossary Drift Check — Shared Procedure

SSOT for the glossary drift check every stage runs (intent, outline, detail, tests, code, docs): the deterministic check, reviewer-raised drift, and the approval list.

## Deterministic check

- Get `<sid>` by running `bash "$AGENTS_MAIN_ROOT/bin/resolve-session-id"` as a standalone command.
- Run `node "$AGENTS_MAIN_ROOT/bin/check-glossary-drift" --session <sid> --stage <stage> --record` as a standalone command.
- Plan stages (intent / outline / detail): run it before the CPA-3 gate check of `skills/_shared/confirm-plan.md`.
- Staged stages (tests / code / docs): stage the targets first, then run it; a record taken before staging fingerprints other content, and the commit gate blocks.
- Rerun it on every later commit that stages targets of the same stage.
- Rerun it after any change to the artifact, the combined glossary, the intent glossary rows, or the check rules; an earlier grant never covers new inputs.
- On a `DRIFT` line, fix the artifact and rerun, or add the term to the intent glossary (CONFIRM_INTENT is taken again).
- To accept a finding unfixed, confirm with the user via AskUserQuestion, then emit the narrow `WORKFLOW_GLOSSARY_ACCEPTED` form the CLI prints.
- Use the term-only form (no identifiers) only when the user accepts every pending finding of that term.

## Reviewer-raised drift

- Reviewers raise judgement drift as numbered concerns tagged per `skills/_shared/combined-glossary.md` (reviewer directives).
- Resolve a tagged concern only by fixing the artifact, recording the term in the intent glossary, or a user-confirmed `WORKFLOW_GLOSSARY_ACCEPTED`.
- tests / code: never count a concern whose text holds `[glossary-drift ` as rejected, whatever `concern-ledger reject` returns (exit 1 after the ledger is gone included); count it as a gap / unresolved.
- review-tests puts such a concern in the RT-5c warnings; review-code-security keeps it out of the all-rejected path.
- tests / code acceptance: confirm via AskUserQuestion, emit `WORKFLOW_GLOSSARY_ACCEPTED`, then close the concern with `concern-ledger accept --id C<N> --reason R` while the ledger still exists.
- outline / detail: before the exit-1 re-delegation to the planner, confirm each tagged concern left unfixed via AskUserQuestion; on acceptance emit `WORKFLOW_GLOSSARY_ACCEPTED`.
- outline / detail: tell the planner in the re-delegation prompt which tagged concerns the user accepted, so it writes `accepted(glossary-drift): <reason>`.
- intent / docs: never emit `WORKFLOW_GLOSSARY_ACCEPTED` for a tagged concern; the user decides from the approval list.

## Approval list

- Put this list in the body of the stage's approval presentation; write `0` under the header when it is empty.
- One row per tagged concern left unfixed:

| Term | Finding | Claude's disposition |
|---|---|---|

- intent: tagged concerns from the CI-4a self-review not reflected in intent.md.
- outline / detail: tagged concerns in the concerns log (`<session-id>-outline-concerns-log.md` / `<session-id>-concerns-log.md`) whose last planner disposition is not `accept and revise`.
- outline / detail: also the tagged concerns left in `unresolved-concerns.json` when the loop did not converge.
- docs: tagged concerns from the UD-4a self-review not reflected in the UD-4 proposal.
- docs: fix a tagged concern the review-docs reviewer raises, or list it the same way in the review_docs completion report.
