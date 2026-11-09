# Glossary — internal terms
<!-- lang-check: ignore -->

Terms the user never sees but many components reference as design concepts.
Entry criteria and form: [rules/docs/glossary.md](../../rules/docs/glossary.md).

### auto user-input risk level
- **Definition**: The risk of Jev answering a user input (clarifications or tool approvals, one shared scale) on the user's behalf: `high` when the input asks for approval, consent, a destructive or publishing act, a gate, or a recovery choice, else `low`; an unknown level counts as `high`.
  Which answerer each level gets is set separately; today `low` may go to Jev and `high` always goes to the user.
- **Related**: [architecture/jev.md](../architecture/jev.md)

### delivery operation

- **Definition**: The hard-to-undo act of landing the change on the default branch — a PR merge or a direct commit and push — performed by `/merge-to-main` right after the USER_VERIFIED confirmation.
- **Related**: [skills/merge-to-main/SKILL.md](../../skills/merge-to-main/SKILL.md)

### dialog ID
- **Definition**: A language-independent identifier of a dialog, written on its SKILL.md procedure line and passed as the AskUserQuestion `metadata.source`; the hook-side classification table assigns each dialog ID one auto user-input risk level.
- **Related**: [architecture/jev.md](../architecture/jev.md)

### first_session_id

- **Definition**: The session id of the first generation of a session chain; it names session-progress.md and the plans.
- **Related**: [architecture/claude-code/progress-file.md](../architecture/claude-code/progress-file.md)

### GATE_ACTION

- **Definition**: The closed-vocabulary confirm gate verdict `next-step --gate` prints: `proceed`, `ask`, `present-and-stop`, `audit-wait`, `audit-block`, or `none`.
  Plan steps meet `audit-wait` and `audit-block` while the pre-confirm audit runs or blocks; skills follow it verbatim and never branch on the display-only `GATE_CONFIRM_<X>` line.
- **Related**: [architecture/claude-code/workflow-runtime.md](../architecture/claude-code/workflow-runtime.md)

### identifier context
- **Definition**: A context the glossary drift check treats as an identifier — a code span, a word next to `_ = $ { }`, a run of uppercase words, or a fixed-form line or fixed-schema heading such as a Tags line; it is matched against identifier spellings only.
- **Related**: [architecture/claude-code/glossary-check/matching-rules.md](../architecture/claude-code/glossary-check/matching-rules.md)

### in-skill step

- **Definition**: An ID-labelled line of a skill's Procedure (`CI-3`, `WI-10`, …); it is not a workflow step, and its heading carries the ID alone.
- **Related**: [rules/prompt.md](../../rules/prompt.md)

### IR

- **Definition**: The intermediate representation that `hooks/lib/command-ir/` builds by parsing a Bash command string.
  Hooks judge a command through this structure instead of matching the raw text with regular expressions.
- **Related**: [architecture/claude-code/shell-command-parsing.md](../architecture/claude-code/shell-command-parsing.md)

### Jev input

- **Definition**: The text sent to Jev as its state for one judgment: a stage's sections, packed within a budget, and the names of the source copies.
  The two-stage judge's query builds it, and the backup subagent reads it first.
- **Related**: [architecture/jev/two-stage-broker.md](../architecture/jev/two-stage-broker.md)

### plan step
- **Definition**: One of the three workflow steps intent, outline, and detail; an earlier plan step takes priority over a later one.
- **Related**: [skills/_shared/priority-hierarchy.md](../../skills/_shared/priority-hierarchy.md)

### pre-commit section marker

- **Definition**: A fixed-form output line by which pre-commit marks entering a section of its checks.
- **Related**: [architecture/claude-code/worker-dispatch/commit-push.md](../architecture/claude-code/worker-dispatch/commit-push.md)

### presentation receipt

- **Definition**: The per-plan-step record the Stop hook writes when a turn closes on a plan's link line: the plan path, the link shown (URL, or the local path where none can be made) and the whole-file content hash.
  The CONFIRM checkpoint lets the echo reach the dialog only when it still matches the plan and spends it; it proves the user was shown the plan, and is not an approval.
- **Related**: [architecture/claude-code/settings/hooks.md](../architecture/claude-code/settings/hooks.md)

### prior-step decision
- **Definition**: A decision made in an earlier plan step; a later plan step may not add to, relax, remove, or reinterpret it.
- **Related**: [skills/_shared/priority-hierarchy.md](../../skills/_shared/priority-hierarchy.md)

### prose context
- **Definition**: Any context the glossary drift check does not treat as an identifier context; it is matched against prose terms, accepting only plurals and heading-line capitalization as the same term.
- **Related**: [architecture/claude-code/glossary-check/matching-rules.md](../architecture/claude-code/glossary-check/matching-rules.md)

### review criteria
- **Definition**: The review rules shared by the four plan review formats, code review, and the CC fallback reviewers: scope, coverage, the reporting minimum, severity definitions, and NFR (non-functional requirement) compliance, kept in one place.
- **Related**: [skills/_shared/review-criteria.md](../../skills/_shared/review-criteria.md)

### review round

- **Definition**: One reviewer run of the shared codex review loop; CAP is the normal ceiling on rounds, and MAX_EXTENSIONS is the extra rounds allowed only while HIGH concerns remain.
  "2+1" means CAP=2 / MAX_EXTENSIONS=1.
- **Related**: [skills/_shared/codex-review-loop.md](../../skills/_shared/codex-review-loop.md)

### SCRIPT_CHECKOUT_ROOT

- **Definition**: The checkout (main or linked worktree) holding the script currently running; each file assigns it once from its own path to find sibling code, never as an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### section heading
- **Definition**: A markdown heading of a plan or context file, such as `## Issues`, that tells the reader what the section is.
- **Related**: [architecture/claude-code/state-dirs.md](../architecture/claude-code/state-dirs.md)

### session chain

- **Definition**: The sequence of sessions formed when work outgrows one session and each next session resumes the previous one with `--from`; its head is the first generation.
- **Related**: [architecture/claude-code/progress-file.md](../architecture/claude-code/progress-file.md)

### session-downstream

- **Definition**: The session that takes over: the generation that resumed another with `--from`.
- **Related**: [architecture/claude-code/session-id-resolution.md](../architecture/claude-code/session-id-resolution.md#session-inheritance-identifiers)

### session-upstream

- **Definition**: The session handed over from: the generation that `--from` resumes.
- **Related**: [architecture/claude-code/session-id-resolution.md](../architecture/claude-code/session-id-resolution.md#session-inheritance-identifiers)

### state handoff reader

- **Definition**: The code that reads a given session's state handoff records and returns them in time order: the session-downstream reads the session-upstream's records for `/resume-session --from` and `--list`, and the supervisor codex input reads its own session's.
  During the migration it also reads that session's legacy handoff.md, inside Migration Code Blocks.
- **Related**: [architecture/claude-code/state-handoff-record.md](../architecture/claude-code/state-handoff-record.md)

### step table

- **Definition**: The single source of the step order, which workflow steps each deliverable type requires, which delivery path drops a step, and each step's commit-gate attribute.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md#the-step-table-deliverable-type-x-pm-type)

### TARGET_CHECKOUT_ROOT

- **Definition**: The checkout (main or linked worktree) of the repository a tool operates on, named by the caller; an ordinary variable, never an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### TARGET_MAIN_ROOT

- **Definition**: The main worktree of the repository a tool operates on, which need not be the agents repository; an ordinary variable, never an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### test case reader
- **Definition**: The per-language part that reads one test file and returns one record per case (name, target, line range, malformed reason); the sweep, the checks, and the retire judgment get these records through the common window, which adds each case's deps.
- **Related**: [architecture/claude-code/test-language-registry.md](../architecture/claude-code/test-language-registry.md)

### user course correction
- **Definition**: A user statement of a fact missing from, or contradicting, an approved earlier plan that redirects the work; a CLI copies it from the transcript into a record kept outside the plan body, so the approval hash does not change.
- **Related**: [skills/_shared/priority-hierarchy/core.md](../../skills/_shared/priority-hierarchy/core.md)
