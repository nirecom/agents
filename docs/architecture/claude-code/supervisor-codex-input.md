# Supervisor Codex Input

The EM Supervisor's Codex engine (`bin/supervisor-findings-codex`, alert and audit modes) used to embed the raw session transcript JSONL into the Codex prompt. That broke in two ways (#2475):

- Size: a long session's transcript easily exceeds the Codex input limit (1,048,576 characters), so the run failed or was silently degraded.
- Signal: most of the raw JSONL is tool output, system reminders and metadata; the facts a reviewer needs — what the user asked for and what the session actually did — were a small fraction of it.

`hooks/lib/supervisor-codex-input.js` replaces the raw embed with an assembled input. This document records what the input contains and why; the classification table itself is owned by `hooks/lib/supervisor-codex-input/rules.js` and is not copied here (CPR-SSOT).

## What the input contains

Six delimited blocks, in order: a header, `HANDOFF`, `USER UTTERANCES`, `ACTIONS SINCE PREVIOUS <MODE> RUN`, `PLAN ARTIFACTS`, `SUPERVISOR STATE`. An empty block renders as `(none)` so a reviewer can tell "nothing happened" from "the block was omitted".

- User utterances are collected over the whole transcript. The user's intent does not expire: a request made at the start of the session still binds what happens at the end.
- Actions (commands, edits, skill/agent invocations, sentinels, hook blocks) are collected only from the transcript cursor onward. Earlier actions were already reviewed by the previous run of the same mode.
- The handoff artifact is read (never written) because it holds the decisions and deviations the transcript alone does not surface — see [handoff-artifact.md](handoff-artifact.md).
- Plan artifacts and the supervisor state give the reviewer the plan to check the actions against.

The header carries counts per record kind and the number of unparsable lines. When the transcript has user entries but no utterance matched, it adds a `schema drift?` warning: the rules depend on the Claude Code transcript schema, and a silent schema change would otherwise shrink the input without anyone noticing.

Every block body is defanged (HTML comment markers and `[... START|BEGIN|END ...]` tags are neutralized) because transcript and handoff text is untrusted and must not forge a block boundary. This mirrors `neutralize_delimiters` in `bin/review-plan-codex`.

## The transcript cursor

Each mode keeps its own cursor (`alert.transcript_cursor`, `audit.transcript_cursor` in the supervisor state file): the transcript path, the number of complete lines already reviewed, the uuid of the last one, and a timestamp.

- The cursor advances only when the engine reports `STATUS: SUCCESS`. A failed or skipped run leaves it in place, so the next run re-reviews the same range — duplication is preferred over a blind spot. The engine prints `CURSOR: advanced|not-advanced` so a failed write is visible.
- Only complete (newline-terminated) lines count; a line still being written is left for the next run.
- The cursor resets to the start of the transcript when the path changed, the file is shorter than the cursor, or the uuid at the cursor no longer matches. A reset over-reads rather than skipping actions.
- Paths are normalized (`toWindowsPath`, then `path.resolve`, case-insensitive on win32) before comparison. Without this, `/c/...` versus `C:\...` would reset the cursor every run, widen the range to the whole session, and push the input back over the size limit.

Alert and audit keep separate cursors because they review at different cadences; sharing one would let an alert run hide actions from the next audit.

## Plan artifacts per mode

- Audit always receives intent, outline and detail: cross-stage coherence is its job.
- Alert receives all three while the session is active, and only the intent once the session is terminated (all `closes_issues` closed, per `bin/supervisor-check-session-active`). A finished session's outline and detail no longer steer the work, while the intent still states what the user asked for.
- With no workflow session id (`UNAVAILABLE`), no plan artifact is read, matching the agents' UNAVAILABLE fallback.

The session ids that name these files (`--sid`, `--wsid`) must be bare tokens (`UNAVAILABLE` included); anything else is rejected before a path is built, so an id cannot steer a read outside the plans directory.

## When the input is still too large

A very long session can exceed the limit even after assembly. The engine then reports an explicit `STATUS: FAILED` with `reason: input too large: ...` rather than truncating: a truncated input would look like a complete review. The cursor does not advance, and the agent's existing manual fallback (the agent reads the transcript itself) runs instead. Repeated audit failures stop through the existing audit retry freeze; no new stop mechanism is added.

## The input guard

The size limit is not specific to the supervisor: any codex launch that receives an over-limit input fails inside codex with an error that does not name the cause. So the check lives in one shared library, `bin/lib/cli-exec-guard.sh`, which owns the limit constant, and every codex launch path calls it on the final file it hands to codex — `codex_core_run` (code review and supervisor findings), `bin/review-plan-codex`, `bin/request-off-clearance` and `bin/github-issues/review-survey-verdict-codex.sh`.

- The guard counts code points, not bytes, and fails closed: an input it cannot measure is treated like an oversized one.
- Each launcher falls back the way it already does for a failed codex run (reviewer fallback, human approval, an `invalid` verdict); the guard adds no new outcome.
- A launch path added later must call the guard too — a single unguarded path reintroduces the unexplained failure.

The same library explains a codex or gemini exit 127. That exit means the child never started, and the usual causes — the CLI missing from `PATH`, or an exported environment too large for the child to start — look identical without a diagnosis line. The second cause is what a script variable named `PROMPT` produced on Windows, where that name is already exported: the whole prompt entered every child's environment. The naming rule that prevents it, and its lint, are in `rules/coding.md` "Shell Variable Names".
