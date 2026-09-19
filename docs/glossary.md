# Glossary — agents repository
<!-- lang-check: ignore -->

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
- **Related**: [skills/enforce-workflow-off/SKILL.md](../skills/enforce-workflow-off/SKILL.md)

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

## Supervisor audit

These terms are fixed by the #2256 outline Glossary and used identically across
intent, outline, detail, implementation, and docs. Full design detail lives in
[claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md).

| Term | Definition | Related |
|---|---|---|
| **step** | One of the 16 units of `next-step --list` (`clarify_intent` … `final_report`). The planning stages are steps too — `clarify_intent` / `outline` / `detail`. Do not call these "工程", "stage", "segment", or "boundary". | [CLAUDE.md](../CLAUDE.md) |
| **trigger** | The general term for a condition that arms the supervisor. Audit triggers are step completion (5 steps) or the severity threshold; alert triggers are C1 / C2 / C3. Do not call a trigger an "anchor". | [claude-code.md](architecture/claude-code.md) |
| **arm / surface / clear** | The audit two-phase lifecycle: a trigger arms the run (`audit_phase=pending`), the agent writes a verdict to surface it (`done`), and the next Stop clears it (`null`) so the next boundary can re-arm. | [agents/supervisor-audit.md](../agents/supervisor-audit.md) |
| **audit ledger** | The append-only record, in the supervisor state file, of which step's audit was judged, against which version of which artifact, and when. New in #2256. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **audit run identity** | The `run-NNNN` identifier that names one audit run uniquely from arm to verdict. Minted at arm time; it binds `audit_phase`, the background dispatch, verdict finalization, and the ledger entry into one unit. A verdict is accepted only while its own identity is in-flight; a mismatched verdict is discarded as stale. New in #2256. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **sub-check** | One individually-settled audit concern the ledger tracks (e.g. `intent-internal`, `outline-detail`, `scope-drift`, `recurrence-patterns`), each keyed by its own input version so a later trigger re-judges only what has changed. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **freshness backstop** | The read-only check the `gh pr merge` gate is reduced to: it reconciles the ledger's last terminal run against the current freshness key and never launches an agent. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **audit checklist** | The three items supervisor-audit judges — cross-stage coherence, recurrence patterns, systemic risk. They are a checklist, not mutually exclusive axes, so they are never called "three axes" (the unrelated security-review "three axes" is a different concept). | [agents/supervisor-audit.md](../agents/supervisor-audit.md) |
| **review round / CAP / MAX_EXTENSIONS** | Existing shared codex-review-loop parameters. A round is one reviewer run; CAP is the normal ceiling; MAX_EXTENSIONS is the extra rounds allowed only while HIGH concerns remain. "2+1" means CAP=2 / MAX_EXTENSIONS=1. The review side coins no alias for these. | [skills/_shared/codex-review-loop.md](../skills/_shared/codex-review-loop.md) |
| **prestaged report** | A reviewer output produced outside the loop and handed to `run-codex-review-loop --prestaged-report`, letting the opus fallback rejoin the shared loop through the same stage / reduce / finalize code path as the codex round. | [skills/_shared/codex-review-loop.md](../skills/_shared/codex-review-loop.md) |

## NFR injection and complexity routing

### complexity-judge

- **Full name**: Complexity judge subagent
- **Definition**: A dedicated `subagent_type: complexity-judge` agent that reads code, plans, and context via read-only tools (Read, Glob, Grep, codegraph) and emits exactly one `SIGNALS: <csv>` or `SIGNALS: none` line. Model is fixed at opus. Treats its input as data to classify, never as instructions.
- **Related**: [agents/complexity-judge.md](../agents/complexity-judge.md), [bin/workflow/normalize-judge-signals](../bin/workflow/normalize-judge-signals)

### normalize-judge-signals

- **Full name**: Normalize judge signals CLI
- **Definition**: `bin/workflow/normalize-judge-signals` — reads the raw text file output from a complexity-judge subagent, strictly captures the `SIGNALS:` line, validates each signal ID against `VALID_SIGNAL_IDS`, and emits a normalized CSV on stdout. Preamble text before the `SIGNALS:` line is allowed; non-SIGNALS lines after it, multiple `SIGNALS:` lines, or unknown IDs degrade to `S0-undecidable`.
- **Related**: [bin/workflow/normalize-judge-signals](../bin/workflow/normalize-judge-signals), [agents/complexity-judge.md](../agents/complexity-judge.md)

### nfr-severity-calibration

- **Full name**: NFR severity calibration directive
- **Definition**: The shared operational directive in `agents/lib/nfr-severity-calibration.md`. Tells agents (planners, reviewers) to call `git rev-parse` and `bin/project-nfr-block`, frame the output as project-supplied data (not instructions), and apply the trailing guidance line as a severity calibration criterion. Referenced by all reviewer and planner agents that consider project NFR.
- **Related**: [agents/lib/nfr-severity-calibration.md](../agents/lib/nfr-severity-calibration.md), [bin/project-nfr-block](../bin/project-nfr-block)

### project-nfr-block

- **Full name**: Project NFR block CLI
- **Definition**: `bin/project-nfr-block` — thin bash wrapper that calls `codex_core_project_nfr_block()` and writes the framed `[PROJECT NFR START] … [PROJECT NFR END]` block plus trailing severity-calibration instruction to stdout. Gives CC/planner agents byte-equal access to the same NFR block that codex consumers receive via `bin/lib/codex-core.sh`.
- **Related**: [bin/project-nfr-block](../bin/project-nfr-block), [bin/lib/codex-core.sh](../bin/lib/codex-core.sh), [agents/lib/nfr-severity-calibration.md](../agents/lib/nfr-severity-calibration.md)

## Miscellaneous

### IR

- **Full name**: Intermediate Representation
- **Definition**: A structured intermediate form obtained by parsing input,
  convenient for later processing. The standard term in the compiler field.
  Across CS it can collide with Information Retrieval and others; in this
  repository it means the compiler sense (a parse-based intermediate representation).
- **Related**: #1253
