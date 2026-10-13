> Shared rubric for the outline-skip and detail-skip judgments (#2460).
> Read by the shared procedure `skills/_shared/jev-two-stage-judge.md`, by Jev (one question per key),
> and by the `agents/plan-skip-judge.md` subagent. Not invoked via the Skill tool.
> This file is the sole place the criteria text lives; call sites reference it by path and never restate it.

Two independent checklists exist: the outline-skip checklist against `intent.md` (before outline.md exists), and the detail-skip checklist against `outline.md` (before the detail stage runs).
A stage may be skipped only when every key of its own checklist is true; one false key runs the stage.

## Outline-skip criteria

### so_c1

Criterion (true = skip allowed): a single obvious approach exists — no plausible competing direction remains after reading intent.md.
Pass example: "Rename an env var across 3 known files" — there is exactly one sane way to do this.
Fail example: "Add a caching layer" — in-process LRU, Redis or a CDN are all plausible; a genuine direction choice exists.

### so_c2

Criterion (true = skip allowed): the files or locations to change are uniquely identified — intent.md (or the survey artifacts) names specific files or modules, not just a goal.
Pass example: intent.md says "edit `bin/foo.sh` around line 40 to add a new flag".
Fail example: intent.md says "improve error handling in the workflow" without naming any file.

## Detail-skip criteria

### sd_single_approach

Criterion (true = skip allowed): no comparison of several kinds of approach, with stated comparison axes, is needed — outline.md leaves one implementation shape.
Pass example: outline.md adopts "add one flag to `bin/report` and print it in `report.js`"; nothing else is on the table.
Fail example: outline.md leaves "a config key vs a CLI flag vs an env var" open, to be weighed on discoverability and migration cost.

### sd_no_open_decision

Criterion (true = skip allowed): no undecided judgment on UX, requirements, risk acceptance or boundary conditions remains in outline.md.
Pass example: outline.md fixes the user-visible message, the accepted risk and the edge cases ("empty input prints nothing").
Fail example: outline.md says "decide during detail whether an empty input is an error or a no-op".

## Judgment rules

- Evaluate every key of the applicable checklist; do not stop at the first pass or fail.
- Ambiguous or unclear context means false (run the stage, not skip it).
- The two checklists are independent: a value of one never implies a value of the other.
- A false sd_no_open_decision only runs the detail stage; it never sends the task back to intent or outline (interim until #2620).

## Output rules

- The subagent answers with exactly one line `SKIP_CONDITIONS: <key>=<true|false>, ...` and nothing else.
- The line names every key of the checklist, delegated or not, each exactly once.
- Only `jev-judge finalize` records the values; no caller passes booleans of its own.
