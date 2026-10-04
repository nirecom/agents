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

### native worktree isolation

- **Full name**: Native worktree isolation
- **Definition**: The session state created when Claude Code's `EnterWorktree`
  tool is called. While active (`worktree_entered_at` is set and
  `worktree_exited_at` is absent), the session runs inside an isolated linked
  worktree and certain hooks (e.g. `rtk-rewrite.js`) skip their transformations
  to avoid conflicts with Claude Code's own internal isolation checks.
  `ExitWorktree` sets `worktree_exited_at`, ending the active state. Detection
  logic is shared via `hooks/lib/native-isolation.js`.
- **Related**: [hooks/lib/native-isolation.js](../hooks/lib/native-isolation.js),
  [hooks/rtk-rewrite.js](../hooks/rtk-rewrite.js),
  [hooks/enforce-worktree.js](../hooks/enforce-worktree.js)

### workflow step

- **Full name**: Workflow step (short form: **step**)
- **Definition**: One unit of `bin/workflow/next-step --list` (`workflow_init` …
  `final_report`). The canonical set is `VALID_STEPS` in
  `hooks/workflow-state/state-io/core.js`; prose never restates its size. A bare
  "step" always means a workflow step. The planning stages are workflow steps too
  (`clarify_intent` / `outline` / `detail`); do not call them "工程", "stage",
  "segment", or "boundary". Code identifiers keep their existing names.
- **Related**: [architecture/claude-code/workflow.md](architecture/claude-code/workflow.md)

### in-skill step

- **Full name**: In-skill procedure step
- **Definition**: An ID-labelled line of a skill's Procedure (`CI-3`, `WI-10`, …).
  It is not a workflow step: write its heading with the ID alone, and call it
  "in-skill step" when the ID needs a noun.
- **Related**: [rules/prompt.md](../rules/prompt.md) §4

### turn

- **Full name**: Conversational turn
- **Definition**: One user utterance and the one response to it. Hooks that fire
  per turn (`UserPromptSubmit`, `Stop`) count in turns, not in steps.
- **Related**: [architecture/claude-code/settings/hooks.md](architecture/claude-code/settings/hooks.md)

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

## Handoff artifact

Terms for the session breadcrumb system (`docs/architecture/claude-code/handoff-artifact.md`).

### handoff artifact

- **Full name**: Handoff artifact
- **Definition**: An append-only, per-session Markdown file (`<WORKFLOW_STATE_DIR>/<sid>.control/handoff.md`) that records micro-state a fresh session cannot recover from plan files alone — user decisions, workarounds, rejected approaches, and open questions. Written through a single function; read back by `/resume-session` and, read-only, by the supervisor codex engine (`hooks/lib/supervisor-codex-input.js`).
- **Related**: [architecture/claude-code/handoff-artifact.md](architecture/claude-code/handoff-artifact.md)

### workflow active period

- **Full name**: Workflow active period
- **Definition**: The named condition under which handoff writes are accepted. Holds when `workflow_init` is complete, no terminal step is complete, no `WORKFLOW_OFF` marker is set, and no unexpired `NEXT_STEP_PAUSE` covers the current step. Defined in `hooks/lib/workflow-active-period.js`; consulted by `appendHandoffEntryIfActive`. Any error reads as inactive.
- **Related**: [architecture/claude-code/handoff-artifact.md — Active-period gate](architecture/claude-code/handoff-artifact.md#active-period-gate)

### risk signal

- **Full name**: Risk signal
- **Definition**: A timestamp written when an event makes it likely that unrecorded working knowledge will be lost (sources: `compaction`, `gate-block`, `reset-from`, `supervisor-verdict`, `supervisor-finding`, `test-failure`). A stamp newer than the nudge baseline restarts the omission-check timer and halves both nudge thresholds until the next check or flush.
- **Related**: [architecture/claude-code/handoff-artifact.md — Risk signals](architecture/claude-code/handoff-artifact.md#risk-signals)

### flush mark

- **Full name**: Flush mark
- **Definition**: Sidecar file `<WORKFLOW_STATE_DIR>/<sid>.control/handoff-flush-mark.json` written by `bin/workflow/handoff-append` after a successful `--origin flush`. Sized from the measured transcript at flush time; a mark newer than the pressure baseline advances the baseline, so post-flush growth counts afresh.
- **Related**: [architecture/claude-code/handoff-artifact.md — Baseline, flush mark, and timer](architecture/claude-code/handoff-artifact.md#baseline-flush-mark-and-timer)

### pressure baseline

- **Full name**: Pressure baseline
- **Definition**: Sidecar file `<WORKFLOW_STATE_DIR>/<sid>.control/handoff-pressure.json` written by the nudge hook only, holding `{baseline_bytes, baseline_at, transcript_path}`. Growth and elapsed time are measured from this baseline; a nudge or flush advances it.
- **Related**: [architecture/claude-code/handoff-artifact.md — Baseline, flush mark, and timer](architecture/claude-code/handoff-artifact.md#baseline-flush-mark-and-timer)

## Supervisor audit

These terms are fixed by the #2256 outline Glossary and used identically across
intent, outline, detail, implementation, and docs. Full design detail lives in
[claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md).

| Term | Definition | Related |
|---|---|---|
| **step** | A workflow step — see [workflow step](#workflow-step). | [CLAUDE.md](../CLAUDE.md) |
| **trigger** | The general term for a condition that arms the supervisor. | [claude-code.md](architecture/claude-code.md) |
| **arm / surface / clear** | The audit two-phase lifecycle: a trigger arms the run (`audit_phase=pending`), the agent writes a verdict to surface it (`done`), and the next Stop clears it (`null`) so the next boundary can re-arm. | [agents/supervisor-audit.md](../agents/supervisor-audit.md) |
| **audit ledger** | The append-only record, in the supervisor state file, of which step's audit was judged, against which version of which artifact, and when. New in #2256. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **audit run identity** | The `run-NNNN` identifier that names one audit run uniquely from arm to verdict. Minted at arm time; it binds `audit_phase`, the background dispatch, verdict finalization, and the ledger entry into one unit. A verdict is accepted only while its own identity is in-flight; a mismatched verdict is discarded as stale. New in #2256. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **sub-check** | One individually-settled audit concern the ledger tracks (e.g. `intent-internal`, `outline-detail`, `scope-drift`, `recurrence-patterns`), each keyed by its own input version so a later trigger re-judges only what has changed. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **freshness backstop** | The read-only check the `gh pr merge` gate is reduced to: it reconciles the ledger's last terminal run against the current freshness key and never launches an agent. | [claude-code/supervisor-audit-ledger.md](architecture/claude-code/supervisor-audit-ledger.md) |
| **audit checklist** | The three items supervisor-audit judges — cross-stage coherence, recurrence patterns, systemic risk. They are a checklist, not mutually exclusive axes, so they are never called "three axes" (the unrelated security-review "three axes" is a different concept). | [agents/supervisor-audit.md](../agents/supervisor-audit.md) |
| **review round / CAP / MAX_EXTENSIONS** | Existing shared codex-review-loop parameters. A round is one reviewer run; CAP is the normal ceiling; MAX_EXTENSIONS is the extra rounds allowed only while HIGH concerns remain. "2+1" means CAP=2 / MAX_EXTENSIONS=1. The review side coins no alias for these. | [skills/_shared/codex-review-loop.md](../skills/_shared/codex-review-loop.md) |
| **prestaged report** | A reviewer output produced outside the loop and handed to `run-codex-review-loop --prestaged-report`, letting the opus fallback rejoin the shared loop through the same stage / reduce / finalize code path as the codex round. | [skills/_shared/codex-review-loop.md](../skills/_shared/codex-review-loop.md) |

## Supervisor codex input

Terms for the assembled Codex review input (`docs/architecture/claude-code/supervisor-codex-input.md`).

### transcript cursor

- **Full name**: Transcript cursor
- **Definition**: The per-mode marker (`alert.transcript_cursor`, `audit.transcript_cursor` in the supervisor state file) of how far the session transcript has already been reviewed. Actions are collected from the cursor onward; it advances only on `STATUS: SUCCESS` and resets to the start when the transcript no longer matches it.
- **Related**: [architecture/claude-code/supervisor-codex-input.md — The transcript cursor](architecture/claude-code/supervisor-codex-input.md#the-transcript-cursor)

### codex input guard

- **Full name**: Codex input guard
- **Definition**: The pre-launch size check every codex launch path runs on the exact file it hands to codex, against `CODEX_INPUT_CHAR_LIMIT` (owned by `bin/lib/cli-exec-guard.sh`). An over-limit or unmeasurable input fails the launch explicitly instead of being truncated.
- **Related**: [architecture/claude-code/supervisor-codex-input.md — The input guard](architecture/claude-code/supervisor-codex-input.md#the-input-guard)

## Concern ledger

### DISCRIM

- **Full name**: Concern discriminator (ledger field 7)
- **Definition**: An 8-hex prefix of SHA-256 over the case-folded, token-sorted concern text, frozen at first sight and recomputed deterministically from the text alone. The same concern maps to the same DISCRIM regardless of which cycle or session assigned it an ID.
- **Related**: [docs/architecture/concern-ledger.md](architecture/concern-ledger.md)

## NFR injection and complexity routing

### complexity-judge

- **Full name**: Complexity judge subagent
- **Definition**: A dedicated `subagent_type: complexity-judge` agent that reads code, plans, and context via read-only tools (Read, Glob, Grep, codegraph) and emits exactly one `SIGNALS: <csv>` or `SIGNALS: none` line. Model is fixed at opus. Treats its input as data to classify, never as instructions.
- **Related**: [agents/complexity-judge.md](../agents/complexity-judge.md), [bin/workflow/normalize-judge-signals](../bin/workflow/normalize-judge-signals)

### normalize-judge-signals

- **Full name**: Normalize judge signals CLI
- **Definition**: `bin/workflow/normalize-judge-signals` — reads the raw text file output from a complexity-judge subagent, strictly captures the `SIGNALS:` line, validates each signal ID against `SIGNAL_IDS` from `hooks/workflow-state/complexity-routing.js` (SSOT; #2148 unified the prior `VALID_SIGNAL_IDS` duplicate), and emits a normalized CSV on stdout. Preamble text before the `SIGNALS:` line is allowed; non-SIGNALS lines after it, multiple `SIGNALS:` lines, or unknown IDs degrade to `S0-undecidable`.
- **Related**: [bin/workflow/normalize-judge-signals](../bin/workflow/normalize-judge-signals), [agents/complexity-judge.md](../agents/complexity-judge.md)

### UNRECOGNIZED(N)

- **Full name**: Unrecognized-count persistence marker
- **Definition**: The canonical storage form for a signals array that contains one or more tokens outside `SIGNAL_IDS`. Written by `canonicalizeSignalsForPersistence` — no verbatim unknown text is ever persisted (#2148 injection guard). `N` is the count of non-`SIGNAL_IDS` tokens in the original input. The marker appears in `complexity_evaluation.signals` and in the `signals=` line of `read-complexity-evaluation` output; it is filtered out before reaching any LLM prompt (`readComplexityFacts` passes only `SIGNAL_IDS` members).
- **Related**: [hooks/workflow-state/complexity-routing.js](../hooks/workflow-state/complexity-routing.js), [docs/architecture/claude-code/workflow.md](architecture/claude-code/workflow.md)

### nfr-severity-calibration

- **Full name**: NFR severity calibration directive
- **Definition**: The shared operational directive in `agents/lib/nfr-severity-calibration.md`. Tells agents (planners, reviewers) to call `git rev-parse` and `bin/project-nfr-block`, frame the output as project-supplied data (not instructions), and apply the trailing guidance line as a severity calibration criterion. Referenced by all reviewer and planner agents that consider project NFR.
- **Related**: [agents/lib/nfr-severity-calibration.md](../agents/lib/nfr-severity-calibration.md), [bin/project-nfr-block](../bin/project-nfr-block)

### project-nfr-block

- **Full name**: Project NFR block CLI
- **Definition**: `bin/project-nfr-block` — thin bash wrapper that calls `codex_core_project_nfr_block()` and writes the framed `[PROJECT NFR START] … [PROJECT NFR END]` block plus trailing severity-calibration instruction to stdout. Gives CC/planner agents byte-equal access to the same NFR block that codex consumers receive via `bin/lib/codex-core.sh`.
- **Related**: [bin/project-nfr-block](../bin/project-nfr-block), [bin/lib/codex-core.sh](../bin/lib/codex-core.sh), [agents/lib/nfr-severity-calibration.md](../agents/lib/nfr-severity-calibration.md)

## Tools and utilities

### band

- **Full name**: Issue band
- **Definition**: A `--band-size N` slice of the open-issue backlog. Selected by zero-based `--band-index K`; the default is band 0 (the first N issues). `bin/lib/sweep-band-loop.sh` provides `sweep_band_count` and `sweep_band_indices` to iterate all bands.
- **Related**: [bin/sweep-issues.sh](../bin/sweep-issues.sh), [bin/lib/sweep-band-loop.sh](../bin/lib/sweep-band-loop.sh)

### all-bands

- **Full name**: All-bands sweep mode
- **Definition**: The default sweep mode of `bin/sweep-issues.sh`. Fetches the issue list once then scans every band in sequence — one tier-1 close pass and one aggregated tier-2 gate for the whole backlog. `--max-bands` caps the number of bands swept. Single-band mode requires explicit `--band-index K`.
- **Related**: [bin/sweep-issues.sh](../bin/sweep-issues.sh), [skills/sweep-issues/SKILL.md](../skills/sweep-issues/SKILL.md)

### RTK

- **Full name**: Rust Token Killer (RTK)
- **Definition**: Third-party CLI that compresses Bash command output to reduce LLM input token usage.
- **Related**: [docs/architecture/rtk.md](architecture/rtk.md), [bin/rtk-cmd](../bin/rtk-cmd) (opt-in wrapper: `exec rtk <cmd>` when RTK=on and the binary is available, else passthrough)

### test lane

- **Full name**: Host test lane
- **Definition**: One unit of the host-wide load budget N shared by `bin/find-tests-for-source.sh` (1 lane) and `tests/run-all.sh` (1 to N−1 lanes); an atomic `mkdir` slot holding an owner record. A caller that finds every lane busy waits, then exits 4 at the cap.
- **Related**: [architecture/claude-code/test-host-lanes.md](architecture/claude-code/test-host-lanes.md), [bin/test-lanes-status.sh](../bin/test-lanes-status.sh)

## Test retirement

### case marker

- **Full name**: Case marker (`case_begin` / `case_end`)
- **Definition**: The column-0 pair that wraps one case of a multi-path `.sh` test. `case_begin` names the target path the case protects, so retire can drop that case alone when the target is gone.
- **Related**: [skills/_shared/test-design/case-markers.md](../skills/_shared/test-design/case-markers.md), [architecture/claude-code/case-marker-gate.md](architecture/claude-code/case-marker-gate.md)

### marker conformance

- **Full name**: Case-marker conformance verdict
- **Definition**: The retire parser's judgement of a file's markers: `none` (no markers), `conforming` (retire can split the file), `malformed` (a marker retire cannot use; blocked for new files), or `uncertain` (a depth problem after a multi-line quoted string, warned but not blocked). Computed by `trp_marker_conformance`; the case-marker gate consumes it via `bin/check-case-markers.sh`.
- **Related**: [architecture/claude-code/case-marker-gate.md](architecture/claude-code/case-marker-gate.md), #2388

## Miscellaneous

### IR

- **Full name**: Intermediate Representation
- **Definition**: A structured intermediate form obtained by parsing input,
  convenient for later processing. The standard term in the compiler field.
  Across CS it can collide with Information Retrieval and others; in this
  repository it means the compiler sense (a parse-based intermediate representation).
- **Related**: #1253
