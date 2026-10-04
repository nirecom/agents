# Jev Integration (shadow mode)

Jev is TypeSafe AI's typed classifier: it answers a fixed list of yes/no
questions about a text and returns one typed answer per question. This
repository calls it as a second opinion on task complexity. It is never a
required dependency, and nothing it returns changes what the workflow does.

## Why it exists

Task complexity is judged by the `complexity-judge` subagent, an LLM call that
costs seconds and tokens on every workflow stage. A typed classifier could
answer the same rubric faster and cheaper — but only if its answers agree with
the judge's. Shadow mode collects that evidence before any decision depends on
it: both judges see the same dispatch, the LLM result is always the one adopted,
and the pair is written to a log for later comparison (#2460, under #2457).

## Enabling

Set `JEV=on` and `TYPESAFE_API_KEY=<key>` in the agents config directory's
`.env` (see `.env.example`); a non-empty value exported into the hook's process
environment takes precedence. The
default is `JEV=off`, and anything other than a case-insensitive `on` reads as
off, including a config that fails to load.

Neither key can be set from a project's `.env.local`: `JEV`,
`TYPESAFE_API_KEY`, and the `JEV_` prefix are on the local-env blocklist, so a
reviewed repository can neither switch the call on nor redirect the credential.
The same list refuses the Node runtime variables that would weaken the call's
TLS or reroute it. See
[local-env-overrides.md](claude-code/local-env-overrides.md).

## How the call is triggered

Two hooks registered on the `Agent|Task` matcher make the call deterministic —
no skill prose has to remember to invoke Jev.

| Hook | Event | What it does |
|---|---|---|
| `hooks/jev-shadow-pre.js` | PreToolUse | Queries Jev for the dispatch and leaves the answer in a pending hand-off file |
| `hooks/jev-shadow-post.js` | PostToolUse | Claims the hand-off, pairs it with the judge's output, and appends the decision record; writes nothing to stdout |

Both act only on a main-conversation dispatch whose `subagent_type` is a
registered consumer — today that is `complexity-judge` alone
(`hooks/lib/jev/registry.js`). Every other dispatch, and every dispatch while
`JEV` is off, exits before any state write or network access.

The query goes to `POST https://api.typesafe.ai/v1/systemone` with
`Authorization: Bearer <TYPESAFE_API_KEY>`. Reachability is probed with
`GET /v1/models`; a successful probe is cached for ten minutes per session. A
failed probe is recorded with its own status — an HTTP error with its code, a
timeout, or unreachable — so a rejected key reads apart from an outage.

## Shadow-mode contract

- **Adopted result**: always the LLM judge's. Every decision record carries
  `adopted: "llm"` and `mode: "shadow"`.
- **Log only**: shadow mode injects nothing into the parent conversation — the
  post hook emits no `additionalContext`. Jev's answer reaches only the decision
  log and `bin/jev-report`, so it cannot steer the model or a downstream parser.
- **One judgment, one record**: counted after `bin/jev-report`'s dedupe by
  (`session_id`, `tool_use_id`). The raw log may hold duplicate rows (a late or
  repeated post); the report folds them into one judgment.
- **Fail-open**: both hooks always exit 0. A missing key, an outage, an open
  breaker, or an unreadable hook payload costs only the shadow record — the
  dispatch proceeds exactly as it would with `JEV=off`.
- **Comparison**: a record is marked as agreeing or disagreeing only when both
  sides produced a usable answer, after the rubric's implications are closed on
  both (`S1b` implies `S1`). A raw answer listing `S1b` without `S1` violates
  that rubric, so when either side (or both) does, `S1` and the record as a
  whole score as disagreement. An `S0-undecidable` answer from either judge is
  not a usable answer, so such a record is left uncompared. A record whose Jev
  side is not ok carries a `fallback_reason`.

## Module map

| Module | Responsibility |
|---|---|
| `hooks/lib/jev/dispatch-gate.js` | Reads hook stdin; decides whether a dispatch is in scope |
| `hooks/lib/jev/registry.js` | Consumer table: threshold, mode, sampling, fallback signal |
| `hooks/lib/jev/broker.js` | Orchestrates one call: key check → breaker → liveness → query; pairs pre and post |
| `hooks/lib/jev/provider-core.js` | The HTTP client: endpoint, timeouts, response cap, status vocabulary |
| `hooks/lib/jev/breaker.js` | Per-session circuit breaker |
| `hooks/lib/jev/liveness.js` | Cached reachability probe |
| `hooks/lib/jev/pending.js` | Pre → post hand-off files, atomic claim, orphan sweep |
| `hooks/lib/jev/decision-record.js` | Builds and appends the decision record |
| `hooks/lib/jev/retention.js` | Removes idle session state |
| `hooks/lib/jev/state-paths.js` | State directory layout and id validation |
| `hooks/lib/jev/sanitize.js` | Terminal-safe renderers for the report's enum and signal-id values |
| `hooks/lib/jev/test-overrides.js` | Captures the test-only overrides |
| `bin/workflow/lib/jev-complexity-adapter.js` | Complexity-specific half: rubric → questions, answers → signals |
| `hooks/lib/jsonl-rotating-log.js` | Locked, rotating JSONL append shared with the RTK guard audit |
| `bin/jev-report` | Local agreement report over the decision log |

The split between `hooks/lib/jev/` and the adapter is deliberate: the first is
consumer-agnostic plumbing, the second is everything that knows what
"complexity" means. A second consumer adds a registry row and an adapter, not a
second broker.

## Failure handling

- **Circuit breaker**: three consecutive outage-class failures (unreachable,
  timeout, HTTP error, `bad-response`) open the breaker for ten minutes for
  that session. After expiry exactly one call is let through: it re-opens the
  breaker for a 30 s trial window (`TRIAL_MS`, longer than a probe plus a query)
  under the state lock, so concurrent dispatches cannot all retry a sick Jev.
  The trial's success resets the count; its failure re-opens for ten minutes.
  A success clears the breaker only if it was not opened after that call's
  admission (its own trial excepted), so a slow late success cannot close a
  breaker that newer failures opened.
  `bad-response` is an HTTP 200 whose body exceeds the 64 KiB cap, is not
  parseable JSON, or has no `answers` object — an outage, not a completed call.
  A parsed response whose answers cannot be mapped, or whose mapped answer the
  signal parser fails to normalize, also counts as `bad-response` for the
  breaker, while its record keeps `unmappable`; only a parsed, mapped answer
  counts as a success.
- **Parser failure**: when normalizing Jev's answer through the signal parser
  fails, the Jev side is recorded as `unmappable` with the fallback answer, so
  the report's fallback reasons never count it as a usable Jev answer.
- **Timeouts**: 2 s for the probe, 6 s for the query, 4 s for normalizing the
  answer through the signal parser. The worst-case chain is 12 s, inside the
  15 s the hook itself is registered with — a hook killed at its timeout skips
  its own cleanup, so the budget is kept below it on purpose.
- **Orphans**: a pending hand-off the post hook never claimed (the dispatch was
  interrupted), or claimed but never logged (the hook was killed before its
  record was written), becomes an `llm-missing` record after one hour, so an
  abandoned dispatch is counted rather than lost. A post with no hand-off whose
  log append failed leaves its LLM-only record behind for the same sweep to retry.
  An unparseable hand-off still becomes a record, built from empty values.
  The sweep claims each entry under its own name, so two leftovers of one
  dispatch whose append failed are both kept for the retry, never one overwriting the other.
  Every hand-off is file content: each field is re-validated (status enums,
  signal IDs, model charset, bounded numbers) before it reaches a record.
- **Unreadable stdin**: with `JEV=on`, the hook writes one stderr diagnostic
  line and skips; with `JEV=off` it stays silent. See
  [hook-stdin-input.md](claude-code/hook-stdin-input.md).

## State and log

State lives under `$AGENTS_STATE_DIR/jev` (default `~/.agents/jev`), one
directory per session: breaker state, the liveness cache, pending hand-offs,
and the short-lived `norm-*` directory that holds a judge's raw text while the
signal parser normalizes it. A sweep runs at most once a day and removes
session directories idle for more than seven days, after emitting their
orphans; one whose orphan could not be logged is kept for the next sweep.
Removal first renames the directory to a `.tomb-<session>-<digits>` tombstone
and re-checks it there: a hook that wrote at the old path meanwhile loses
nothing, because a tombstone that gained entries is restored (or merged into
the recreated directory without overwriting) and is not counted as removed.
A hand-off write that finds its directory renamed away mid-write recreates it
and retries once. A tombstone left by a killed sweep is restored or merged back
the same way when it holds pending entries (a conflicting name keeps the
tombstone), so the next due sweep handles them; one free of entries is cleaned
once stale. The temporary directory lives here rather than in the system temp
directory for that reason: one left behind by a killed hook is removed with its
session instead of staying forever.

Decisions are appended to `jev-decisions.log` as JSONL (record version 1) and
rotated by size. This is analysis data, not production state: deleting it loses
only the evidence collected so far.

`bin/jev-report` aggregates that log — agreement rate overall and per signal,
the count of comparisons excluded because either judge answered S0-undecidable, record counts per stage, fallback reasons, latency percentiles for both judges,
and estimated cost. A judgment logged twice (a duplicate or late post) is counted
once, and the number dropped is reported. When a post arrives after its pending
was swept, the Jev-only orphan and the LLM-only record are merged into one
judgment and compared again. Any other direct consumer of the log must likewise
dedupe by (`session_id`, `tool_use_id`), since that case leaves two records.
`s1b_without_s1` counts, per judge, the `ok` answers that list `S1b` without
`S1` — the raw rubric gap that the comparison scores as disagreement (see
**Comparison** above); the low-confidence reference applies the same rule.
Latency is taken from every side whose call completed — Jev `ok`,
`low-confidence` or `unmappable`, LLM `ok` or `parse-fallback` — so a parsed
answer that could not be mapped still counts the time it cost. Outages
(including `bad-response`), unrun sides and an `unmappable` recorded before any
query (its questions could not be built) count no latency. For
Jev it is the query POST's duration, probe excluded; for the LLM, from the end of
the Jev round trip to the post hook's start. The per-signal low-confidence rate
is taken over Jev records that answered (`ok` or `low-confidence`) and reports
that count as its n; this rate, like every other rate in the report, is null
(`n/a` in text) when its denominator is zero. A rotated log
generation that exists but cannot be read is listed as unreadable (and warned
about on stderr) rather than silently skipped. It reads local files only and
never contacts Jev. Usage is in `bin/jev-report --help`.

## Security properties

- **Redaction before truncation**: every text that leaves the machine — the
  dispatch prompt and each plan artifact — passes through two redactors before
  the 16 000-character cap is applied, so truncation cannot leave a credential's
  prefix in the request, and the request's recorded size and hash describe the
  redacted string actually sent. The first
  (`hooks/workflow-state/complexity-routing/secret-shape.js`) redacts provider key
  shapes; the second (`redactSecrets` in `hooks/lib/output-sanitize.js`) adds
  `github_pat_` tokens, URL userinfo credentials, `Authorization` scheme values,
  `token=` / `password:`-style assignments, and private-key blocks of any PEM kind.
- **One pattern source with the pre-commit scanner**: the first redactor loads
  its shapes from the `# BEGIN hard-secret-patterns` / `# END hard-secret-patterns`
  block in `bin/scan-outbound.sh`, so a shape the scanner learns is redacted
  from Jev requests too, with no copy to drift. Every match is redacted
  wherever it occurs, whatever precedes it — a glued key cannot slip through
  as prose.
- **Fail closed on missing patterns**: if that block cannot be loaded, the
  redactor throws rather than pass text through unredacted; the request is then
  never built, no query is sent, and the Jev side is recorded as `not-run`.
- **Bounded artifact reads**: each plan artifact is read only up to 1 MiB,
  far above the state cap, so an oversized file cannot stall the hook or
  exhaust memory; the request header's line count covers that portion only.
- **Same plan as the LLM judge**: plan artifacts are read from the `Session-ID`
  in the dispatching worktree's `WORKTREE_NOTES.md` (that one file, never a
  sibling or the process cwd) when it has any, else from the hook session id,
  because the workflow session id can differ from the Claude Code one and the
  comparison is fair only if Jev sees the plan the LLM sees. The notes id is
  adopted only when its workflow state's `session_worktree`, or the latest
  worktree-entered event's own `cwd` (not a fallback-process-cwd), equals the hook cwd (normalized; case-insensitive on
  Windows only); a `cwd` that falls back to the session-start context never binds,
  because every main-checkout session shares that start cwd. So a stale or copied
  notes file never lends another session's plan. The recorded workflow step is
  the hook session's, falling back to that bound notes session's — the same
  check — when the hook session has no workflow state.
- **No redirect, bounded response**: the client refuses HTTP redirects — a
  redirect would forward the bearer token to another host — and stops reading a
  response at 64 KiB.
- **The key stays out of records**: the API key is held in a non-enumerable
  field and never reaches the decision log or a diagnostic.
- **Test override is loopback-only**: `JEV_BASE_URL` is honoured only for
  `127.0.0.1` / `localhost` without credentials, and is captured from the
  process environment before `.env` is loaded, so no config file can supply it.
  `JEV_HTTP_TIMEOUT_MS` takes effect only together with that loopback override,
  so it can never stretch a production query past the hook's budget.
- **Path safety**: session and tool-use ids are validated against a strict
  character set before they are used in a state path.
- **Untrusted output**: everything rendered into the text report is sanitized; Jev's response is treated as data, never as
  instructions.
- **State root**: `AGENTS_STATE_DIR` is on the local-env blocklist, so a
  reviewed repository cannot relocate where state and logs are written.
- **Untrusted names**: a point name read from a hand-off file or a log row is
  matched against the registry's own keys only, and the report groups rows in
  prototype-less maps, so a name such as `constructor` is an ordinary unknown
  point rather than an inherited property.

## Known limits

None changes the shadow-mode contract.

- Because every `sk-` match is redacted, ordinary words that contain it
  (`task-complexity-signals-file`) reach Jev with that span redacted while the
  LLM judge sees them intact — an A/B input difference on the Jev side only,
  accepted so that no glued key leaves the machine.
- Process-runtime variables other than Node's own remain settable from a
  project `.env.local` — the general limit described in
  [local-env-overrides.md](claude-code/local-env-overrides.md).
- A `norm-*` directory left by a killed hook stays until its session directory
  has been idle for seven days.

## Rollout

Shadow mode is opt-in per machine, not per checkout. The hooks run from the
agents config directory (`$AGENTS_CONFIG_DIR`), and `JEV` is read from a
non-empty value already in the hook's process environment, else from that
config directory's `.env`; a project's `.env.local` is never consulted for it.
The flag ships off, so merging the feature changes nothing for any session
until that environment or config `.env` turns it on. Promotion past
shadow mode — letting Jev's answer be adopted — is a separate decision that the
agreement data from `bin/jev-report` is meant to inform.
