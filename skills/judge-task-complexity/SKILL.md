---
name: judge-task-complexity
description: Evaluate task context and return a model routing verdict (opus or sonnet) with matched signal IDs. Called by other skills before launching a subagent. Not intended to be invoked directly by users.
model: sonnet
---

Evaluate the task context passed by the caller and return a single-line verdict.

## Complexity Signals

| Signal ID | Trigger condition |
|-----------|-------------------|
| S1-multi-file | Estimated change spans 3 or more files |
| S2-architecture | Task involves design decisions, architectural changes, or system-wide refactors |
| S3-security | Task touches authentication, authorization, secrets, cryptography, or permissions — regardless of whether the change is code-only, docs-only, or config-only |
| S4-installer | Task modifies install scripts, dotfiles bootstrap, or system configuration |
| S5-breaking | Task introduces breaking changes to public APIs or inter-process contracts |
| S6-long-plan | Prior-stage artifacts (intent.md / outline.md) exceed 200 lines combined |

## Routing Rule

- 1 or more signals triggered → `opus`
- 0 signals triggered → `sonnet`
- Parse failure or ambiguous context → `opus` (err toward higher capability)

## Output Format

Emit exactly one line as your entire response.

If signals matched:
```
VERDICT: opus | <comma-separated signal IDs>
```
Example: `VERDICT: opus | S1-multi-file, S3-security`

If no signals:
```
VERDICT: sonnet | none
```

No preamble, no explanation, no trailing text. The pipe (`|`) and signal list are mandatory.

## Rules

- Evaluate ALL signals before emitting the verdict — do not short-circuit on the first match
- "Security documentation" counts as S3-security. The boundary applies to subject matter, not artifact type.
- When file count cannot be precisely determined, err toward opus (S1-multi-file)
- Never emit anything other than the single VERDICT line
