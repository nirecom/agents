> Shared rubric. Read explicitly by `clarify-intent` at step CI-3a (decomposition probe).
> Not invoked via the Skill tool — caller reads this rubric and emits the verdict in its own output.
> Structure mirrors `judge-task-complexity.md` so both rubrics can share the same evaluation loop.

Evaluate the scoped task from the clarify-intent interview against the signals below.
Signals measure structural decomposability, NOT task size or overall complexity.

## Decomposition Signals

| Signal ID | Trigger condition |
|-----------|-------------------|
| D1-multi-deliverable | Scope contains 2+ independently shippable deliverables, each with distinct acceptance criteria that can be satisfied separately |
| D2-sequential-dep | A "merge A before starting B" ordering dependency exists between identified parts of the scope |
| D3-orthogonal-subsystem | Scope spans 2+ orthogonal subsystems where each part can be independently reviewed, tested, and reverted |
| D4-distinct-risk | Parts of the scope carry clearly different risk profiles requiring separate revert units (e.g. schema migration + UI change) |
| D5-explicit-phasing | User has explicitly described the work in phases, milestones, or "first X, then Y" sequencing during the interview |

## Routing Rule

- 2 or more signals triggered → `wf-meta` (propose to user — NEVER auto-switch without confirmation)
- 0–1 signals → `wf-code` (proceed silently, no user prompt)
- Parse failure or ambiguous context → `wf-code` (fail toward smaller scope)

## Output Format

The caller emits exactly one line in its own output:

If ≥2 signals:
```
VERDICT: wf-meta | <comma-separated signal IDs>
```

If <2 signals:
```
VERDICT: wf-code | none
```

## Rules

- Evaluate ALL signals before emitting the verdict — do not short-circuit on the first match
- A large but unified task (single deliverable, single risk profile) scores 0 signals and stays wf-code
- When wf-meta is proposed, present concrete named sub-deliverables (not an abstract "is this big?" question)
- NEVER switch to wf-meta without user confirmation via AskUserQuestion
- When zero PR history is available, evaluate signals from interview content alone — do not hang or error
