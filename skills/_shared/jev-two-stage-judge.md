# JEV Two-Stage Judge

Shared by every caller of a JEV judgment point (`complexity-judge`, `outline-skip`, `detail-skip`).
The caller names point `<P>` and stage `<S>`; output keys and exit codes: `bin/workflow/jev-judge` (SSOT).
Keep the caller's own `Model selected:` line unchanged.

## JJ-1 Query

- Run, with the working worktree as cwd: `node "$AGENTS_MAIN_ROOT/bin/workflow/jev-judge" query --session "<SESSION_ID>" --point <P> --stage <S>`.
- Read `RESULT`, `TICKET`, `SUBAGENT`, `SNAPSHOT_FILE`, `ANSWER_FILE` and `SOURCES_DIR` from its KEY=VALUE output.
- `RESULT=final`: go to JJ-3.
- Exit 2 or 3: apply the JJ-5 fail-safe with TICKET `-`.

## JJ-2 Subagent (only on `RESULT=need-subagent`)

- Dispatch `subagent_type: <SUBAGENT>`; build its prompt per the Subagent Dispatch Prompts section of `rules/shell-commands.md`.
- Pass the `SNAPSHOT_FILE` path and tell the subagent to read it first.
- Pass the `SOURCES_DIR` path: the header's `sources` lists file names only, because the snapshot is what Jev is sent.
- Tell it to read the full copies listed under the header's `sources`, inside `SOURCES_DIR`, only when the snapshot marks a section truncated or absent, or the snapshot alone cannot decide; it reads no other file.
- Tell it to answer undecidable when a section listed under `sources_unavailable` is truncated or absent and needed.
- Tell it to return the answer on its last line.
- Write that answer to `ANSWER_FILE` with the Write tool; write `NO_ANSWER` when it is empty.
- Never put the answer text on a command line; it reaches jev-judge only through `ANSWER_FILE`.

## JJ-3 Finalize

- Run `node "$AGENTS_MAIN_ROOT/bin/workflow/jev-judge" finalize --session "<SESSION_ID>" --ticket <TICKET>`.
- On any exit other than 0 or 4, re-run the same command exactly once; finalize is idempotent per ticket, so the re-run cannot change the verdict.
- `RESULT=ok`: go to JJ-4.
- `RESULT=error` (exit 4), or still no exit 0 after the re-run: go to JJ-5.

## JJ-4 Downstream (`RESULT=ok`)

- Pass the `SIGNALS_CSV` printed by finalize, never the fixed signals file; when it is empty, pass `--signals ""`.
- complexity, `SETTLE=ok`, stage `complexity`: run `node "$AGENTS_MAIN_ROOT/bin/workflow/record-complexity-evaluation" --session "<SESSION_ID>" --signals "<SIGNALS_CSV>"`.
- complexity, `SETTLE=ok`, any other stage: run `node "$AGENTS_MAIN_ROOT/bin/workflow/derive-complexity-level" --stage <S with _ for -> --signals "<SIGNALS_CSV>"` and use its `model=`.
- complexity, `SETTLE=superseded`: a newer judgment owns this stage, and its caller continues the step.
  Do not write any file, do not record or derive, and stop this step.
  Never hand this case to JJ-5 and do not apply a fail-safe.
  Run /supervisor-report with REASON=complexity-superseded, then run `next-step` and follow it; when the step is still current, restart it from JJ-1.
- skip: follow `SKIP=`; finalize has already settled the step, and `SETTLE=superseded` prints `SKIP=false`.

## JJ-5 Fail-safe

Apply when finalize returns `RESULT=error` (exit 4), finalize still fails after the JJ-3 re-run, or query exits 2 or 3.
Report every case with /supervisor-report and a REASON.

- complexity: run `node "$AGENTS_MAIN_ROOT/bin/workflow/jev-judge" failsafe --session "<SESSION_ID>" --point complexity-judge --stage <S> --ticket <TICKET|->`.
  `SETTLE=ok`: pass its `SIGNALS_CSV` to the JJ-4 complexity `SETTLE=ok` downstream.
  `SETTLE=superseded`: stop exactly as the JJ-4 complexity superseded case.
  failsafe exit 2 or 3: write nothing and do not stop; outside stage `complexity`, use `derive-complexity-level --stage <S with _ for -> --signals "S0-undecidable"` (high / opus) for this run only.
- skip: run `node "$AGENTS_MAIN_ROOT/bin/workflow/jev-judge" failsafe --session "<SESSION_ID>" --point <outline-skip|detail-skip> --stage <S> --ticket <TICKET|->`, then treat the result as `SKIP=false` and run the step.
  Run the step even when failsafe exits 3.
