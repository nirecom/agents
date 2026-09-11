# Session-ID Resolution

What this file owns: the boundary between the two identifier families, why the resolver is
supplied-only, the `bin/resolve-session-id` bridge's rc contract, and the contract of the static
guard. The chain's 4-tier shape is described in
[workflow.md](workflow.md#bashcli-side-resolution) and is not repeated here.

## Two identifier families that share one variable name

| Family | Question it answers | Canonical resolver |
|---|---|---|
| CC session UUID | which process am I? | `hooks/workflow-state/session-id.js` — `resolveSessionId()` |
| Workflow session id | which plan artifacts are mine? | `hooks/lib/resolve-workflow-session-id.js` — `resolveWorkflowSessionId()` |

They are different concepts: one identifies the running agent, the other names a namespace of
files. The confusion is that both travel under the env var name `SESSION_ID`, so a caller that
exports it for one family silently satisfies the other's check with a wrong value.

Merging the two, or renaming the variable, is a non-goal here. Renaming crosses skill
procedures, scripts, and the shells that invoke them at once, and the payoff is naming hygiene
rather than a fixed failure. The families stay separate and are stated, not unified.

## Supplied-only: no filesystem inference

`resolveSessionId()` is a strict 4-tier SUPPLY-only chain, tried in order and returning the
first match:

1. `ctx.sessionIdFromInput`
2. `CLAUDE_CODE_SESSION_ID` — CC-native, reliably present in the Bash-tool subprocess where the
   manufactured relay below is not (#1082, Anthropic bug #27987)
3. `CLAUDE_SESSION_ID`
4. `ctx.transcriptPath` basename

All four come from the calling process's own context, so none of them can name a different
session. When none match, it returns `null` — never a guess.

An earlier chain additionally inferred an id from filesystem traces — `CLAUDE_ENV_FILE`,
`WORKTREE_NOTES.md` scanning in the caller's own worktree, and a JSONL mtime scan across
transcript directories — as lower-priority tiers, gated by an `allowFilesystemInference` flag
that fail-closed callers set to `false`. That inference was removed entirely (this diff, #2270):
in a concurrent environment it could return the session that was last active rather than the
caller's own (#1082), and every caller that needs a session id either has one of the four
supplied sources or should fail rather than guess. There is no flag to opt back into inference;
the chain has only the one shape now.

The same reasoning explains why several sites read the env directly instead of calling the
resolver at all: a scratchpad allow root, a session-scoped marker file, and an audit
attribution id each get *worse* if an inference fills the gap. Those sites carry an inline
waiver naming the role (below).

Note: `hooks/lib/resolve-workflow-session-id.js` — the *workflow*-session-id resolver, a
different family (see the table above) — is untouched by this change and still reads
`WORKTREE_NOTES.md` and does a JSONL mtime scan for its own namespace. Nothing here bears on
that resolver's behavior.

## The bridge rc contract

`bin/resolve-session-id` wraps `resolveSessionId()` for bash callers that cannot `require()` the
Node module directly. It is the canonical (SSOT) definition of these exit codes — every caller
maps rc 2 to "no session" and treats every other non-zero rc as a fault to propagate or fail
closed on, never as "no session":

| rc | Meaning |
|---|---|
| 0 | stdout carries the resolved session id |
| 2 | session id unresolvable — no supplied tier had one; the *only* "no session" rc |
| 3 | the resolver itself threw — a bridge fault, distinct from "no session" |
| 70 | invoked through `node` instead of `bash` (#1532 misinvocation guard) |
| 127 | `node` not found on `PATH` |

`bin/review-code-ledger` and `tests/fix-882-resolve-worktree-path/cases-2270-bridge-rc.sh` both
read this table as authoritative rather than restating the contract themselves.

## The static guard

`bin/check-session-id-ssot.sh` flags session-id env reads that bypass the resolver. It runs from
`hooks/pre-commit` in the agents repo and blocks on rc 1 (violations) and rc 2 (usage error — a
mistyped flag must not read as a pass).

**In scope:** Node `process.env` access to `SESSION_ID`, `CLAUDE_SESSION_ID`, or
`CLAUDE_CODE_SESSION_ID`, written either dotted or as a bracket with a string literal. Detection
is by construct, not by file extension, so a `node -e` program embedded in a bash script is
scanned like any other Node source.

**Out of scope, deliberately:**

- *Bash `$SESSION_ID` expansion.* Not statically separable from a local variable of the same
  name; flagging it produces dozens of false positives in scripts that expand a value they were
  handed on a `--session` flag.
- *Computed `process.env[name]`.* Undecidable without dataflow analysis.
- *`WORKFLOW_SESSION_ID`.* A different family, and every read site uses it as an explicit
  override checked *before* delegating to a resolver — a sanctioned contract, not a bypass.
  Revisit if the workflow-session-id family gains a bash bridge and the override shape settles.

The guard stops new direct reads from landing. It does not prove the tree has none: propagation
through the `env` command and the two undecidable forms above are outside what a static scan can
see, and no completeness is claimed.

**Exemptions.** The guard alone owns the exemption lists; they are not duplicated here. Two
kinds exist: whole-file allowlist entries, reserved for the canonical resolvers themselves, and
per-line inline waivers spelled `session-id-ssot: waived (<role>) — <reason>` on the read's own
line or the line above. A waiver with an empty reason is treated as a violation, since a marker
with nothing behind it is the rubber stamp the guard exists to prevent.

## Known limitations and follow-up candidates

- **No bash bridge for the workflow-session-id family.** `resolveSessionId()` has
  `bin/resolve-session-id`; `resolveWorkflowSessionId()` has no equivalent. Six skill scripts
  therefore still require the caller to export `SESSION_ID`:
  `skills/review-tests/scripts/run-codex-review-loop.sh`,
  `skills/review-plan-security/scripts/run-codex-review-loop.sh`,
  `skills/make-detail-plan/scripts/run-codex-review-loop.sh`,
  `skills/make-outline-plan/scripts/run-codex-review-loop.sh`,
  `skills/make-outline-plan/scripts/check-detail-skip.sh`,
  `skills/make-outline-plan/scripts/check-outline-skip.sh`.
  They fail loudly (`${SESSION_ID:?}`) rather than skipping silently, so the gap is visible
  rather than dangerous. Adding the bridge means a new PATH-exposed entrypoint with its own
  output contract and tests, applied to all six sites at once.
- **Bridge-caller migration is partial (CPR-ORTH gap).** `bin/resolve-session-id`'s rc=3
  fail-closed fault contract landed with this diff, but not every caller that shells out to a
  bridge-shaped script was migrated to distinguish rc=3 (fault) from rc=2 (no session) — e.g.
  `skills/worktree-start/scripts/derive-worktree-name.sh`, `bin/resolve-merge-base.sh`, and the
  `codex-core.sh` / `gemini-core.sh` provider wrappers. Each still treats any non-zero rc
  uniformly. Filed as a followup in the same spirit as #2273.
