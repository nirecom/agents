# OFF Legitimacy Rubric (SSOT)

Single source of truth for judging whether a WORKFLOW_OFF / WORKTREE_OFF departure reason is legitimate.
Consumers: `bin/request-off-clearance` (Phase1 examination), `agents/supervisor.md` checklist item 6.

## Verdicts

Emit exactly one verdict: `ALLOW` or `REJECT`.

## REJECT categories (a sanctioned alternative exists)

- `cleanup` — leftover worktrees/branches; `/sweep-worktrees` reclaims them without OFF.
- `instructions-unread` — prompt or hook instructions were not read; read them and proceed in order.
- `convenience` — OFF is merely faster or easier; convenience is never a legitimate departure.

## ALLOW categories (leaving the workflow is justified)

- `workflow-bug` — a next-step / workflow / hook defect blocks correct progress.
- `trivial-change` — the change is so small that worktree isolation cost is disproportionate.
- `urgent-external` — customer response or an urgent incident outranks the workflow (private-info leakage is one example).

## Judgment rules

Do not decide on the category enum alone — the enum is a pre-classification hint.
Weigh the free-text `detail` against these criteria and reject a mislabeled request.
Reject when the stated detail describes an available sanctioned path, whatever category was declared.
Allow only when the detail concretely shows the sanctioned path is unavailable or disproportionate.

## Sanctioned WIP commits are NOT an OFF bypass

`git -c workflow.wip=1 commit` (`--wip` mode) is a sanctioned mechanism authorized by `hooks/workflow-gate.js`; it skips `user_verification` only.
It is a different mechanism from the WORKFLOW_OFF / WORKTREE_OFF sentinels and is NOT an improvised bypass.
Never classify a `--wip` commit as a C3 improvised bypass or as an OFF proposal.
