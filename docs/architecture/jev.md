# Jev Integration

Jev is TypeSafe AI's typed classifier: it answers a fixed list of yes/no
questions about a text and returns one probability per question. It is never a
required dependency.

- Three stage points make it the first judge of task complexity and of skipping
  the outline or detail plan; with Jev off, down or unsure, a subagent judges.
- Two conversation points read the current turn: `continuation`
  (wait-on-invoke / continue-on-stop) and `askuser-answer`. Unsure or failing, they change nothing.

## Why it exists

Each stage judgment used to be an LLM subagent call costing seconds and
tokens on every workflow stage. A typed classifier answers the same rubric
faster and cheaper, and it reports how sure it is. So Jev answers the keys it
is confident about, and the subagent is dispatched only for the rest — often
for none. A shadow period (#2460, under #2457) collected the agreement data
that justified adopting Jev's answers; Jev shadow mode (Jev answers, only the
log keeps it, the subagent decides) remains as a per-point fallback.

## Enabling

Set `JEV=on` and `TYPESAFE_API_KEY=<key>` in the agents config directory's
`.env` (see `.env.example`); a non-empty value exported into the process
environment takes precedence. The default is `JEV=off`, and anything other than
a case-insensitive `on` reads as off, including a config that fails to load.
With `JEV=off` the same procedure runs, every key is delegated to the subagent,
and nothing is logged.

Neither key can be set from a project's `.env.local`: `JEV`,
`TYPESAFE_API_KEY`, and the `JEV_` prefix are on the local-env blocklist, so a
reviewed repository can neither switch the call on nor redirect the credential.
The same list refuses the Node runtime variables that would weaken the call's
TLS or reroute it. See
[local-env-overrides.md](claude-code/local-env-overrides.md).

## How the call is triggered

Every caller of a judgment point follows one shared procedure
(`skills/_shared/jev-two-stage-judge.md`) around the `bin/workflow/jev-judge`
CLI:

| Command | What it does |
|---|---|
| `jev-judge query` | Builds the Jev input from the stage's sources, asks Jev, gates the answers, and says whether a subagent is needed |
| `jev-judge finalize` | Merges Jev's and the subagent's answers, appends the decision record, and settles the result |
| `jev-judge failsafe` | Settles the point's safe-side result when the two above could not |

The subagent dispatch sits between `query` and `finalize` because only the main
conversation can dispatch one. The protocol — tickets, the gate, write-ahead,
owner markers — is in [jev/two-stage-broker.md](jev/two-stage-broker.md).

Two hooks on the `Agent|Task` matcher (`hooks/jev-shadow-pre.js`,
`hooks/jev-shadow-post.js`) remain for shadow mode: they observe a dispatch
whose `subagent_type` belongs to a point in shadow mode and record the pair.
For any other dispatch, and whenever `JEV` is off, they exit before any state
write or network access.

The query goes to `POST https://api.typesafe.ai/v1/systemone` with
`Authorization: Bearer <TYPESAFE_API_KEY>`. Reachability is probed with
`GET /v1/models`; a successful probe is cached for ten minutes per session. A
failed probe is recorded with its own status — an HTTP error with its code, a
timeout, or unreachable — so a rejected key reads apart from an outage.

## Rollout modes

Each point in `hooks/lib/jev/registry.js` carries its own policy. The registry
owns these values; the table shows the values the switch to production shipped
with, and every decision record carries the ones actually applied.

| Point | Mode | Backup subagent | Threshold: yes / no | Short-circuit |
|---|---|---|---|---|
| `complexity-judge` | production | `complexity-judge` | 0.7 signal fires / never adopted (does not fire goes to the subagent) | when the adopted signals already decide high at every stage the judgment feeds |
| `outline-skip` | production | `plan-skip-judge` | 0.9 skip allowed / 0.7 run | on "run" |
| `detail-skip` | production | `plan-skip-judge` | 0.9 skip allowed / 0.7 run | on "run" |

- **`production`**: Jev's answer is adopted for every key whose confidence
  reaches the threshold for that answer's direction; the other keys go to the
  backup subagent. The CLI writes the decision record.
- **`shadow`**: every key goes to the subagent and Jev's answer is logged only.
  The hook pair records a point it can match by `subagent_type`; the CLI
  records every other point.
- **Per-direction thresholds**: a skip point demands more confidence to skip a
  planning stage than to run it, because a wrong skip loses a review while a
  wrong run only costs time. Complexity never adopts Jev's "absent" until data
  sets a threshold: a wrong low loses quality, a wrong high costs a model tier.
- **Short-circuit**: for a skip point, one criterion adopted as "does not hold"
  decides "run" without asking about the rest. Complexity short-circuits on
  adopted signals only when they are decisive: the adapter reads the routing
  table and confirms they route every stage the judgment feeds to high (all
  stages for stage `complexity`, its own stage otherwise). S3 alone is not
  decisive at outline or detail, so it still delegates there. The routing
  table is read at query time; a later table change only matters if the
  persisted levels are lost and re-derived from the signals.
- **Required sections**: per stage, the sections that must reach Jev whole.
  The issue body is required at every stage, the intent where no plan sections are named. A section is
  exempt only when its producing step was skipped or the session has no issue.
  When a required section is missing, Jev is not asked.
- **Policy freeze**: a ticket keeps the policy it was queried under, so a
  registry change takes effect from the next ticket queried.
- **Fail-safe direction**: any failure resolves to the costlier-but-safe side —
  `S0-undecidable` (highest routing level) for complexity, "run the stage" for
  a skip. Jev can remove a subagent call; it cannot remove a planning stage on
  a failure.

### What can be rolled back, and how

- **By data**: Jev's adoption. Setting a point's `mode` to `"shadow"`, raising
  a threshold, or setting `JEV=off` returns the judgment to the subagent, with
  no other change.
- **By `git revert` only**: what shipped alongside the switch and is code or
  rubric — the retired complexity signals, the end of the zero-signal automatic
  skip, the retired skip verifier and its scripts, and the replaced detail-skip
  criteria. Changing `mode` does not bring those back.

## Conversation points

A conversation point asks one Jev query about the current turn, with no backup
subagent and no ticket; only a confident yes acts.

- **`wait-on-invoke`**: on `ACTION=invoke`, next-step asks once per
  step and turn (a child with a 3 s limit, cached in the control directory) and
  adds `JEV_ADVICE=wait-on-invoke` with a fixed `JEV_ADVICE_REASON`. A step is
  advised at most once, so the advice cannot loop. Hooks run next-step with
  `--jev-cache-only` through `hooks/lib/next-step-spawn.js` and never query.
- **`continue-on-stop`**: where the Stop guard would let a stop pass,
  it asks whether work remains; a confident yes blocks the stop once per turn.
  It never asks while a human or a delegated step is waited on.
- **AskUserQuestion**: a PreToolUse hook answers only a dialog Claude marked
  eligible (`metadata.source` = `jev-auto-skip-askuser`), and only when every
  question has exactly one confident option. The marker is an allowlist: an
  unmarked dialog reaches the user with no Jev call and no record; plan-approval
  waits, `user_verification` and multi-select stay excluded even when marked.
  `JEV_AUTO_SKIP_ASKUSER=off` turns it off alone.
- An optional `user-instructions-jev.md` at the checkout root adds the user's
  own rules to the input.

## Module map

| Module | Responsibility |
|---|---|
| `bin/workflow/jev-judge` | CLI entry: argument check, then `query` / `finalize` / `failsafe` |
| `hooks/lib/jev/two-stage/` | The CLI path: query, gate, Jev input, merge, write-ahead replay, owner markers, fail-safe, orphan handling |
| `hooks/lib/jev/registry.js` | Point table and its schema check; who records a judgment |
| `hooks/lib/jev/broker.js` | Orchestrates one Jev call: key check → breaker → liveness → query; pairs the shadow hooks |
| `hooks/lib/jev/dispatch-gate.js` | Reads hook stdin; decides whether a dispatch is a shadow point's |
| `hooks/lib/jev/provider-core.js` | The HTTP client: endpoint, timeouts, response cap, status vocabulary |
| `hooks/lib/jev/breaker.js` | Per-session circuit breaker, split by cause |
| `hooks/lib/jev/liveness.js` | Cached reachability probe |
| `hooks/lib/jev/pending.js` | Hand-off files and tickets, atomic claim and takeover, orphan sweep |
| `hooks/lib/jev/decision-record.js` | Builds the decision record; appends once per ticket and record type |
| `hooks/lib/jev/conversation-point.js`, `conversation-record.js`, `adapters/` | Conversation points: one query about the turn, its record, the per-point adapters |
| `hooks/lib/jev/retention.js` | Removes idle session state |
| `hooks/lib/jev/state-paths.js` | State directory layout, id validation, versioned reads |
| `hooks/lib/jev/sanitize.js` | Terminal-safe renderers for the report's values |
| `hooks/lib/jev/test-overrides.js` | Captures the test-only overrides |
| `bin/workflow/lib/jev-request-common.js` | Shared request pieces: capped reads, session binding, redaction, per-stage sections |
| `bin/workflow/lib/jev-complexity-adapter.js` | Complexity half: rubric → questions, answers → signals |
| `bin/workflow/lib/jev-skip-adapter.js` | Skip half: one question per skip criterion, the subagent's answer file |
| `hooks/lib/jsonl-rotating-log.js` | Locked, rotating JSONL append shared with the RTK guard audit |
| `bin/jev-report`, `bin/lib/jev-report-aggregate/` | Local report over the decision log |

`hooks/lib/jev/` is point-agnostic plumbing; an adapter holds everything that
knows what its point means. A new point adds a registry row and an adapter, not
a second broker.

## Failure handling

- **Circuit breaker, by cause**: transport failures (unreachable, timeout, HTTP
  error) count in one scope shared by every point, because a sick Jev is sick
  for all of them. A `bad-response` — an answer set the adapter cannot map —
  counts in a scope of its own per point, so one point's bad answers never
  block another. Three consecutive failures open a scope for ten minutes.
  After expiry exactly one call is let through: it re-opens the scope for a
  30 s trial window (`TRIAL_MS`, longer than a probe plus a query) under the
  state lock, so concurrent calls cannot all retry a sick Jev. A success
  clears a scope only if it was not opened after that call's admission (its
  own trial excepted), so a slow late success cannot close a breaker that
  newer failures opened.
- **Timeouts**: 2 s for the probe, 6 s for the query. The worst-case chain is
  8 s, inside the 15 s the shadow hook is registered with — a hook killed at
  its timeout skips its own cleanup, so the budget is kept below it on purpose.
- **Jev failure on the CLI path**: any status other than `ok` delegates every
  key, with the status as the record's `fallback_reason`. The judgment then
  costs one subagent call, as it did before Jev.
- **Incomplete input**: a required section that is truncated, absent, over the
  read cap, or whose copy failed means Jev is not asked
  (`input-insufficient`).
- **`RESULT=error` and the caller's fail-safe**: when `finalize` cannot
  complete, the caller re-runs it once and then runs `jev-judge failsafe`,
  which settles the safe-side result.
- **Stopped mid-finalize**: the merged result is written ahead of every side
  effect, and each later step is idempotent, so a re-run or the orphan sweep
  finishes a stopped ticket with the outcome an uninterrupted run would have
  had.
- **Superseded**: when a judgment queried later owns the stage, the older
  ticket settles nothing. A superseded complexity caller writes nothing and
  stops; a superseded skip reads as "run".
- **In-process normalization**: complexity answers go through the signal
  parser's exported `normalize()` (`bin/workflow/normalize-judge-signals`) in
  process. The raw judge text is never written to the decision log.
- **Orphans**: a ticket or hand-off nobody completed becomes a record after one
  hour, so an abandoned judgment is counted rather than lost. Every hand-off is
  file content: each field is re-validated before it reaches a record.
- **Unreadable hook stdin**: with `JEV=on`, the hook writes one stderr
  diagnostic line and skips; with `JEV=off` it stays silent. See
  [hook-stdin-input.md](claude-code/hook-stdin-input.md).

## State and log

State lives under `$AGENTS_STATE_DIR/jev` (default `~/.agents/jev`), one
directory per session: breaker scopes, the liveness cache, pending hand-offs
and tickets, and done markers. Each state file carries a version constant owned
by the module that writes it; a file of another version reads as absent, so a
format change needs no migration. A sweep runs at most once a day and removes
session directories idle for more than seven days, after emitting their
orphans. Removal goes through a `.tomb-<session>-<digits>` tombstone that is
restored or merged back if a writer raced it, so no pending entry is lost.

Two markers live in the session control directory beside the files they guard:
the owner marker of the fixed `<stage>-signals.txt` and the owner marker of a
skip judgment. The judgment queried later owns the marker. A caller's
downstream therefore uses the `SIGNALS_CSV` its own `finalize` printed, never
the fixed file.

Every judgment appends one version 2 record to `jev-decisions.jsonl` (formerly
`jev-decisions.log`, moved on first append), rotated by size. It is analysis
data, not production state: deleting it loses only evidence. Each record names
its `point`, where it was judged (`judged_in`), the probabilities, thresholds,
whether Jev was adopted, and why not. Fields, the per-point `final` shapes, the
rename and the report's reading of them: [jev/decision-record.md](jev/decision-record.md).

`bin/jev-report` reads local files only and never contacts Jev. It drops a
repeated (`ticket`, `record_type`) and reports the count, excludes superseded
tickets from every rate while counting them, and lists a rotated log
generation it could not read rather than skipping it silently. Reading the
report and acting on it: [ops.md](../ops.md#jev).

## Security properties

- **Redaction before truncation**: every text that leaves the machine passes
  through two redactors before the character cap is applied (`MAX_STATE_CHARS` for the
  shadow adapter's state, `MAX_JEV_INPUT_CHARS` for the CLI's Jev input), so truncation
  cannot leave a credential's prefix in the request, and the recorded size and hash
  describe the redacted string actually sent. The first (`hooks/workflow-state/complexity-routing/secret-shape.js`) redacts provider
  key shapes; the second (`redactSecrets` in `hooks/lib/output-sanitize.js`)
  adds `github_pat_` tokens, URL userinfo credentials, `Authorization` scheme
  values, `token=` / `password:`-style assignments, and private-key blocks.
- **One pattern source with the pre-commit scanner**: the first redactor loads
  its shapes from `HARD_SECRET_PATTERNS` in `hooks/lib/outbound-scan/hard-secret-patterns.js`,
  the list the scanner itself uses, so a shape the scanner learns is redacted
  from Jev requests too. Every match is redacted wherever it occurs.
- **Fail closed on missing patterns**: if that list cannot be loaded or is empty, the
  redactor throws rather than pass text through; no query is sent.
- **Bounded reads**: each source and the answer file are read only up to 1 MiB.
- **The answer never rides a command line**: the subagent's answer reaches
  `finalize` only through the ticket's own answer file, whose path `finalize`
  derives itself.
- **Same plan as the subagent**: plan artifacts are read from the `Session-ID`
  in the dispatching worktree's `WORKTREE_NOTES.md` when it has one, else from
  the session id given. The notes id is adopted only when that session's
  recorded worktree equals the current one, so a stale or copied notes file
  never lends another session's plan.
- **No redirect, bounded response**: the client refuses HTTP redirects — a
  redirect would forward the bearer token to another host — and stops reading a
  response at 64 KiB.
- **The key stays out of records**: the API key is held in a non-enumerable
  field and never reaches the decision log or a diagnostic.
- **Test override is loopback-only**: `JEV_BASE_URL` is honoured only for
  `127.0.0.1` / `localhost` without credentials, and is captured from the
  process environment before `.env` is loaded, so no config file can supply it.
  `JEV_HTTP_TIMEOUT_MS` takes effect only together with that override.
- **Path safety**: session, ticket and tool-use ids are validated against a
  strict character set before they are used in a path.
- **Untrusted output**: everything rendered into the text report is sanitized;
  Jev's response is treated as data, never as instructions.
- **State root**: `AGENTS_STATE_DIR` is on the local-env blocklist, so a
  reviewed repository cannot relocate where state and logs are written.
- **Untrusted names**: a point name read from a file or a log row is matched
  against the registry's own keys only, and the report groups rows in
  prototype-less maps, so `constructor` is an ordinary unknown point.
- **Untrusted transcript content**: only `User:` lines count as the user's
  intent. Continuation lines are prefixed `  | ` so a body cannot forge a
  `User:` line, and tool inputs and results are framed as untrusted data.
- **Transcript path**: the path in `prompt-turn.json` is read only as a `.jsonl`
  under `<CLAUDE_CONFIG_DIR or ~/.claude>/projects/`; any other reads as absent.

### What is sent to Jev

With `JEV=on`, data leaves the machine for `api.typesafe.ai`:

| Point | Sent |
|---|---|
| `complexity-judge`, `outline-skip`, `detail-skip` | The stage's sources (issue body, plan sections), redacted and capped |
| `continuation` (next-step invoke, Stop) | The current turn: user and assistant text, tool inputs and results, redacted, capped at `MAX_STATE_CHARS` |
| `askuser-answer` (marked AskUserQuestion only) | The current turn's user and assistant text and tool names (no tool inputs or results), and the dialog's questions and options |

Both conversation points also send the user prompt that opened the turn, in its own block that
the turn's truncation never cuts: it is the user's own words, the evidence a judgment rests on.
Meta injections (skill expansions, hook context), compaction summaries and sidechain entries are
never sent as the user's words.
`user-instructions-jev.md`, when present, goes with both conversation points.
Redaction removes secret-shaped strings only; `JEV=off` stops every send and
`JEV_AUTO_SKIP_ASKUSER=off` stops the dialog point's.

## Known limits

- Because every `sk-` match is redacted, ordinary words that contain it
  (`task-complexity-signals-file`) reach Jev with that span redacted while the
  subagent sees them intact — an input difference on the Jev side only,
  accepted so that no glued key leaves the machine.
- Run-direction agreement is not measured in production: a ticket Jev decides
  alone has no subagent answer to compare with. Measuring it means putting the
  point back in shadow mode for a while.
- A registry change cannot be forced onto tickets already queried; they finish
  under their frozen policy within the one-hour ticket lifetime.
- Process-runtime variables other than Node's own remain settable from a
  project `.env.local` — the general limit described in
  [local-env-overrides.md](claude-code/local-env-overrides.md).

## Rollout

Jev is opt-in per machine, not per checkout (see Enabling): the flag ships off,
so merging changes no judgment until that environment turns it on. Lowering a
skip threshold is a separate, human decision the report's retune section informs.
