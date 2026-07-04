# Glossary — agents repository

An index of the abbreviations and workflow stage names that recur across the
agents repository. It is the entry point for going from an unfamiliar term to
its canonical definition in the fewest hops.

Terms are grouped by category. Within each group they run from the more general
concept to the more specific, and — where the terms name a sequence — in the
order the steps occur. Each entry carries a full name, a one- to two-line
definition, and related links.

---

## Workflow

### workflow

- **Full name**: Workflow
- **Definition**: The end-to-end sequence of steps from clarify → outline →
  detail → implementation → verification → close. Each stage is denoted by a
  `WF-<TYPE>-N` prefix, with progress managed by hooks and sentinels.
- **Related**: [CLAUDE.md](../CLAUDE.md)

### sentinel

- **Full name**: Sentinel
- **Definition**: A marker string of the form `<<WORKFLOW_...>>`. Hooks detect it
  to drive workflow state transitions and gate open/close — stage-complete marks,
  skip declarations, OFF switches, and the like.
- **Related**: [rules/workflow-off.md](../rules/workflow-off.md)

### meta

- **Full name**: Meta issue
- **Definition**: A GitHub issue for planning or architecture with no
  implementation. Identified by a `Group:` title prefix and the `meta` label;
  the actual work is carried by its sub-issues.
- **Related**: [rules/github-issues.md](../rules/github-issues.md)

### WF-META

- **Full name**: Workflow Meta step
- **Definition**: `WF-META-N` is the planning-only step number (no worktree) for
  meta issues. It carries no implementation and goes only as far as filing the
  sub-issues.
- **Related**: [CLAUDE.md](../CLAUDE.md)

### WF-CODE

- **Full name**: Workflow Code step
- **Definition**: `WF-CODE-N` is the step number in the standard implementation
  flow that uses a linked worktree — the code-implementation TYPE within the
  `WF-<TYPE>-N` prefix scheme.
- **Related**: [CLAUDE.md](../CLAUDE.md)

## Workflow steps

### intent

- **Full name**: Intent (Agreed Requirements)
- **Definition**: The scope, motivation, and non-goals that `clarify-intent`
  settles through dialogue with the user. The agreed baseline from which all
  later planning starts.
- **Related**: [skills/clarify-intent/SKILL.md](../skills/clarify-intent/SKILL.md)

### outline

- **Full name**: Outline plan
- **Definition**: Two or three mutually exclusive high-level approach candidates
  and the selection among them. Follows intent and precedes detail; produced by
  `make-outline-plan`.
- **Related**: [skills/make-outline-plan/SKILL.md](../skills/make-outline-plan/SKILL.md)

### detail

- **Full name**: Detail plan
- **Definition**: The stage that turns an approved approach into a file-level
  implementation plan (files to change, steps). Follows outline; produced by
  `make-detail-plan`.
- **Related**: [skills/make-detail-plan/SKILL.md](../skills/make-detail-plan/SKILL.md)

## Miscellaneous

### IR

- **Full name**: Intermediate Representation
- **Definition**: A structured intermediate form obtained by parsing input,
  convenient for later processing. The standard term in the compiler field.
  Across CS it can collide with Information Retrieval and others; in this
  repository it means the compiler sense (a parse-based intermediate representation).
- **Related**: #1253
