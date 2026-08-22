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

## Notes

- The checkpoint's `phase` field is written for diagnostics; the resume path
  derives its entry phase from `ask_id`, never from `phase`.
- `WID_DRIVER_OVERRIDE` is a harness-self-check seam only (runs the suite against a
  stand-in driver outside the repo); it is NOT part of the driver contract.
