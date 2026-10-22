# Glossary — user terms
<!-- lang-check: ignore -->

Terms the user sees directly: skill names, `.env` settings, sentinels, workflow steps, and confirmation dialogs.
Entry criteria and form: [rules/docs/glossary.md](../../rules/docs/glossary.md).

### AGENTS_MAIN_ROOT

- **Definition**: The environment variable naming the main worktree of the agents repository, where the user's configuration (`.env`, private-info lists) is read from.
  It is exported by the shell profile and never used to locate code.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### confirm gate

- **Definition**: A per-step user-confirmation point switched by a `CONFIRM_*` flag (intent, outline, detail, tests, code, docs, worktree).
- **Related**: [skills/_shared/confirm-plan.md](../../skills/_shared/confirm-plan.md)

### deliverable type

- **Definition**: What a session builds, `wf-code` or `wf-meta`, recorded in the state field `deliverable_type`.
  It picks the column of the step table that says which workflow steps are required or skipped.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md#the-step-table-deliverable-type-x-pm-type)

### delivery path

- **Definition**: Where a session ships, set by `ENFORCE_WORKTREE` rather than chosen: `pull_request` (merged through a PR) or `direct` (commit and push to the default branch).
  It only drops workflow steps; it never reorders them.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md)

### detail

- **Definition**: The workflow step that turns the approved approach into a file-level implementation plan; produced by `/make-detail-plan` after outline.
- **Related**: [skills/make-detail-plan/SKILL.md](../../skills/make-detail-plan/SKILL.md)

### handoff artifact

- **Definition**: The append-only per-session breadcrumb file that hooks and skill procedures write — context events, gate blocks, deviations, outcomes; the main conversation's own facts go to session-progress.md.
  `/resume-session` reads it back, and the supervisor codex engine reads it read-only.
- **Related**: [architecture/claude-code/handoff-artifact.md](../architecture/claude-code/handoff-artifact.md)

### intent

- **Definition**: The scope, motivation, and non-goals that `/clarify-intent` settles with the user; the agreed baseline every later plan starts from.
- **Related**: [skills/clarify-intent/SKILL.md](../../skills/clarify-intent/SKILL.md)

### Jev

- **Definition**: A third-party typed classifier that returns one probability per yes/no question; with `JEV=on` it is the first judge at the complexity and outline / detail skip judgments.
- **Related**: [architecture/jev.md](../architecture/jev.md)

### meta

- **Definition**: A planning or architecture GitHub issue with no implementation, marked by a `Group:` title prefix and the `meta` label; its sub-issues carry the work.
- **Related**: [rules/github-issues.md](../../rules/github-issues.md)

### outline

- **Definition**: The workflow step that proposes two or three mutually exclusive approaches and selects one; produced by `/make-outline-plan` between intent and detail.
- **Related**: [skills/make-outline-plan/SKILL.md](../../skills/make-outline-plan/SKILL.md)

### plan-sync

- **Definition**: The mechanism that pushes each final plan file to a private GitHub or GitLab remote, so a response can carry a plan link readable from a phone or browser.
  `bin/plan-link` prints a session's plan-link line.
- **Related**: [architecture/claude-code/plan-sync.md](../architecture/claude-code/plan-sync.md)

### PM type

- **Definition**: How a session proceeds (project management type): `waterfall` (step order enforced), `off` (the `WORKFLOW_OFF` marker), or `agile` (planned, not implemented).
  Chosen in intent and never switched mid-session; orthogonal to the deliverable type.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md#the-step-table-deliverable-type-x-pm-type)

### presentation turn

- **Definition**: The turn in which the model presents a plan (intent, outline, or detail) in a text block that ends with its plan-link line.
  The `CONFIRM_<STAGE>` echo follows that text block in the same turn when the Stop hook prompts for it, or else after the user replies; it reaches the dialog only when a link-closed presentation was recorded.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md)

### RTK

- **Definition**: Rust Token Killer, a third-party CLI that compresses Bash command output to cut LLM input tokens; enabled with `RTK=on`.
- **Related**: [architecture/rtk.md](../architecture/rtk.md)

### sentinel

- **Definition**: A marker string of the form `<<WORKFLOW_...>>` that hooks detect to drive workflow state — step-complete marks, skip declarations, OFF switches, and the like.
- **Related**: [skills/enforce-workflow-off/SKILL.md](../../skills/enforce-workflow-off/SKILL.md)

### WF-CODE

- **Definition**: The `WF-CODE-N` step prefix of the standard implementation flow, which works in a linked worktree.
- **Related**: [CLAUDE.md](../../CLAUDE.md)

### WF-META

- **Definition**: The `WF-META-N` step prefix of the planning-only flow for meta issues; no worktree, no implementation, ends at filing the sub-issues.
- **Related**: [CLAUDE.md](../../CLAUDE.md)

### workflow

- **Definition**: The end-to-end sequence from clarify through outline, detail, implementation, and verification to close, numbered with `WF-<TYPE>-N` and driven by hooks and sentinels.
- **Related**: [CLAUDE.md](../../CLAUDE.md)

### workflow step

- **Definition**: One unit of `next-step --list` (`workflow_init` … `final_report`), abbreviated to step: a bare "step" always means a workflow step.
  The planning stages (`clarify_intent`, `outline`, `detail`) are workflow steps too; prose never restates the size of the set.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md)
