> Shared rubric. Read explicitly by `workflow-init` (step A3a), `clarify-intent`
> (step CI-C1b), and `make-outline-plan` (steps MOP-1d, MOP-C1) when evaluating
> whether the outline or detail planning stage can be skipped. Not invoked via
> the Skill tool — the caller reads this rubric and evaluates the criteria in
> its own output, then passes the resulting booleans to `record-skip-judgment`.

Two independent checklists exist. The **outline-skip checklist** (so_c1/so_c2)
is evaluated against `intent.md`, before outline.md exists. The **detail-skip
checklist** (sd_c1/sd_c2/sd_c3) is evaluated against `outline.md`, before the
detail stage runs. A stage may be skipped only when **every** criterion in its
own checklist is true — a single false criterion forces the stage to run.

## Outline-skip criteria (so_*)

| ID | Criterion | Pass example | Fail example |
|----|-----------|---------------|---------------|
| so_c1 | A single obvious approach exists — no plausible competing direction remains after reading intent.md | "Rename an env var across 3 known files" — there is exactly one sane way to do this | "Add a caching layer" — could be in-process LRU, Redis, or a CDN; a genuine direction choice exists |
| so_c2 | Change files/locations are uniquely identified — intent.md (or survey artifacts) names specific files/modules, not just a goal | intent.md says "edit `bin/foo.sh` around line 40 to add a new flag" | intent.md says "improve error handling in the workflow" without naming any file |

Routing: so_c1 AND so_c2 both true → outline stage may be skipped. Either false → run the outline stage.

## Detail-skip criteria (sd_*)

| ID | Criterion | Pass example | Fail example |
|----|-----------|---------------|---------------|
| sd_c1 | All changed files are listed by path | outline.md enumerates every file to touch, e.g. `skills/foo/SKILL.md`, `bin/foo` | outline.md says "update the relevant skill files" without naming them |
| sd_c2 | Each file's edit content is clear | outline.md states the exact change per file ("add a 1-line pointer after step X") | outline.md states only the goal per file, leaving the edit shape open |
| sd_c3 | No unresolved multi-layer design decisions | outline.md's Adopted approach is final; no "TBD: decide schema vs config" note remains | outline.md's Delivery plan defers a cross-cutting decision (e.g. "decide CLI flag shape during detail") |

Routing: sd_c1 AND sd_c2 AND sd_c3 all true → detail stage may be skipped. Any false → run the detail stage.

## Rules

- Evaluate every criterion in the applicable checklist before emitting a verdict — do not short-circuit on the first pass/fail.
- Parse failure or ambiguous context → treat the criterion as false (err toward running the stage, not skipping it).
- The two checklists are evaluated independently — a true so_c1/so_c2 does not imply anything about sd_c1–sd_c3, and vice versa.
- Callers pass raw booleans (`--c1`/`--c2`[/`--c3`]) to `record-skip-judgment` — this file is the sole place the criteria text lives; call sites reference it by path and must not restate the criteria inline.
