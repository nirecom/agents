# feature-workflow-init-driver harness contract

Authoritative description of the injection seams `bin/workflow/workflow-init-driver`
must honor for `tests/feature-workflow-init-driver/_lib.sh` to drive it. `_lib.sh`
carries a one-line pointer here; this file is the SSOT.

## Injection seams (write-code contract)

- `gh` is spawned via bare PATH lookup (never an absolute path) — the harness
  intercepts it with a PATH-prepended mock; fixtures live in `$RESP` and every
  invocation appends one line to `$GH_LOG` (call-count assertions C2/C6/C7/C12).
- `wip-state.sh` is resolved as `$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh`
  when `AGENTS_CONFIG_DIR` is set (repo-root-relative fallback only when unset).
  The harness points `AGENTS_CONFIG_DIR` at a per-case mock config root.
- The checkpoint JSON (`<sid>-wi-checkpoint.json`) and `context.md` are written
  under the directory given by the `WORKFLOW_PLANS_DIR` env var when set.
- `CLAUDE_SESSION_ID` provides the session id deterministically; the mock config
  root also ships `bin/resolve-session-id` echoing `$CLAUDE_SESSION_ID` in case the
  driver unconditionally spawns that primitive.
- `NON_GITHUB=1` activates the WI-2 non-GitHub gate.
- Positional CLI args are the raw issue tokens (`#N`, `repo#N`, `owner/repo#N`)
  from the user's invocation; zero tokens = zero-issue pipeline (Path C).
  `intent.md` does NOT exist at workflow-init time — never read it.
- On checkpoint version mismatch the driver ignores the checkpoint's phase/ask
  position and restarts the pipeline, re-detecting issues from the positional
  tokens supplied on that same invocation when there are any — otherwise from the
  stale checkpoint's own `state.issues`, recovered as `#N` tokens (the documented
  resume invocation passes no positional token, so without that recovery the
  restart would run on an empty set; asserted by C14a/C14b). This is the migration
  path for `CHECKPOINT_VERSION` bumps (#2087): a pre-bump checkpoint is discarded
  rather than replayed against a reordered `PHASE_ORDER`.
- `issue-view-<N>.json` may carry a `comments` array (#2063); `mock_issue` seeds it
  empty and the driver's single `gh issue view` must request the field. The mock
  honours the projection: when `--json` is passed and its comma-separated list has no
  exact `comments` token, the key is stripped from the response, so a driver that asks
  for the wrong field (or none) sees no comments at all. The projection is applied only
  to a payload that parses as a JSON object: bytes that do not parse, and JSON that
  parses to `null`, an array or a scalar, reach the driver untouched — that is the
  malformed-fetch seam (C11h, C11i).
- After `reopen` is answered to `closed_reopen_<N>`, `issue view` runs exactly one
  more time for THAT issue only — never for the session's other issues (the upper
  bound the reopen call-count assertions depend on).
- `mock_issue_comments <N> <raw>` splices its payload into the fixture verbatim, so
  it can inject unhealthy or syntactically broken `comments` values for corruption
  cases; `__DELETE__` removes the key.
- `mock_issue_stderr <N> <text>` stages the STDERR text the forced-failure path prints
  (`issue-view-<N>.err`, read only when `issue-view-<N>.rc` is non-zero). gh's own
  failure output is third-party text that may carry a leaked credential, so this is the
  seam for the secret-at-the-subprocess-boundary case (C16).
- `mock_reopen_rc <N> <rc>` / `mock_reopen_stderr <N> <text>` stage a forced failure for
  `gh issue reopen <N>` (`issue-reopen-<N>.rc`, and `issue-reopen-<N>.err` read only when
  the rc is non-zero) — symmetric with the `issue view` seam. The reopen is a WRITE
  against the authoritative remote, so its failure arm is the seam for the
  `issue_reopen_failed` contract and the leaked-credential hunt
  (`driver-issue-comments/reopen-authz.sh` C23).
- `mock_issue_body <N> <text>` (`driver-issue-comments/_lib.sh`) replaces the fixture's
  issue `body` with arbitrary text, JSON-escaped. `mock_issue` hardcodes the body, so
  this is the seam for the issue's OWN untrusted content — the other two surfaces the
  shared `stripSentinels` serves are the body and the title (the title travels through
  `mock_issue`'s 4th argument).

## Notes

- The checkpoint's `phase` field is written for diagnostics; the resume path
  derives its entry phase from `ask_id`, never from `phase`.
- A case that needs the REAL `gh` (the live pagination case C14) must issue those reads
  outside `setup_case`/`teardown_case`: inside a case the PATH-prepended mock answers
  them. Such cases are gated on `RUN_TL3` plus `WI_COMMENTS_LIVE_ISSUE` (`owner/repo#N`)
  and print `SKIP: … Skipped-Because: …` when the gate is closed.
- `WID_DRIVER_OVERRIDE` is a harness-self-check seam only (runs the suite against a
  stand-in driver outside the repo); it is NOT part of the driver contract.
