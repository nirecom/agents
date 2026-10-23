# Progress Update

`<rootSid>-session-progress.md` is the main conversation's own record of where the work stands; it survives compaction and session hand-over, so a fresh session can resume from it.

A step here means a workflow step (one unit of `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list`); `docs/glossary-user.md` owns the term.

## Where the file is

Get the path with `node "$AGENTS_MAIN_ROOT"/bin/progress-file path --session <sid>`; never build the file name yourself.

A resumed session keeps writing the first generation's file: the CLI resolves the root session for you.

## What to write

Rewrite the `Current state` section on every update: what is being done now and what comes next, in a few lines.

Overwrite `Current state`; never turn it into a diary or append dated entries.

Keep `Current state` within the `progress` limit of `rules/coding/file-split.md` (Pattern E); the edit-time size check blocks an edit over it.

When this session writes its own intent, outline, or detail plan, point the `Plan files` lines at it; an inherited file still names the donor session's plans.

Add only facts a fresh session cannot recover from any other file, under the four kinds of fact (`Facts to carry over`):
- user decision (`User decisions`) — a decision the user made in conversation that no artifact records yet.
- deviation (`Deviations`) — a workaround, a fallback, a scope expansion, a flaky result.
- rejected approach (`Rejected approaches`) — what was rejected, with the reason it was rejected.
- open question (`Open questions`) — a question carried forward to the next session.

Never write:
- the content of the intent, outline, or detail plan — write where the plan file is, not what it says;
- step state, step completion reports, or approvals — `next-step --list` and the state file own them;
- a fact already recorded in substance, even with different wording.

## How to write

Write with the Edit tool on session-progress.md; never write these facts into handoff.md.

Keep the template's section headings; add bullets under the matching kind.

Write nothing to the user about the update; the Edit is the whole action.

## When to write

Write a fact at the moment it happens; do not wait for a request.

When a `[progress check]` request arrives, update the file if anything changed since the last update; if nothing changed, write nothing and continue.

When the request also says to tell the user something, say only that one sentence.

Run the same check when the context window is nearly full or the session is being handed to another agent.

The user can force an update with `/update-progress`.

## Who writes

Only the main conversation writes session-progress.md.

A subagent never writes session-progress.md and never acts on a `[progress check]` request.

## Readers

`/resume-session --from`, the post-compaction notice, and the supervisor codex engine read session-progress.md; treat it as the model's own record, not as evidence.

Design, request timing, and the state file: `docs/architecture/claude-code/progress-file.md`.
