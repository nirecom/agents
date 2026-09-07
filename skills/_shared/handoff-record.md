# Handoff Record Catalog

What each step writes into the handoff artifact. When to write it is owned by the calling skill's step; the line grammar is owned by `docs/architecture/claude-code/handoff-artifact.md`.

Write every entry with `node "$AGENTS_CONFIG_DIR/bin/workflow/handoff-append"`, passing `--class` / `--step` / `--key` / `--summary` / `--pointer` / `--origin`.

Use `--pointer -` when no canonical artifact owns the detail.

Keep `--summary` to one line; the pointer's target owns the full content (CPR-SSOT).

## Scope

Only classes D and E have per-step schemas. Classes A–C, F, and G follow the common contract for every step — never write a step-specific format for them.

## Cross-session entries (`--step -`)

| class | key | Trigger | summary | pointer |
|---|---|---|---|---|
| D | `env-guard-workaround` | A `WORKFLOW_OFF` / `WORKTREE_OFF` sentinel was used, or a guard blocked a sanctioned command and a workaround got through | Which guard blocked what, and the form that got through | `-` |
| E | `supervisor-reported` | `bin/supervisor-report` is about to return 0 (written by that CLI itself) | category + severity + topic | `<PLANS_DIR>/<sid>-supervisor-state.json` |

## Per-step entries

| step | class | key | Trigger | summary | pointer |
|---|---|---|---|---|---|
| `review_tests` | E | `review-tests:sentinel` | RT-5b / RT-5c emitted a sentinel | which sentinel + `token=` value + warnings count | `<PLANS_DIR>/<sid>-test-review-unresolved-concerns.json` |
| `review_tests` | D | `review-tests:codex-exit` | `run-codex-review-loop.sh` is about to exit 4 / 7 / 8 (written by that script) | exit code + route taken | `<PLANS_DIR>/<sid>-test-review-codex-round-<N>-raw.md` |
| `write_tests` | E | `write-tests:not-needed` | `WORKFLOW_WRITE_TESTS_NOT_NEEDED` was emitted | why tests are not needed | `-` |
| `write_tests` | D | `write-tests:model-fallback` | WT-5 took the `NONE` fallback | how the level was derived without a persisted evaluation | `<PLANS_DIR>/<sid>-write-tests-signals.txt` |
| `write_code` | E | `write-code:checks-skipped` | WCD-5 surfaced a `check skipped` note | which check was skipped and why | `-` |
| `write_code` | D | `write-code:scope-expansion` | WCD-5 surfaced a scope-expansion note | the approved scope expansion | `<PLANS_DIR>/<sid>-detail.md` |
| `run_tests` | D | `run-tests:flaky` | Re-running changed a test's result | target test + how it was stabilized | `-` |
| `run_tests` | E | `run-tests:sentinel-recovery` | RNT-9 took the overwritten-sentinel recovery or the `NONE` route | which recovery route was taken | state file path |
| `commit_push` | D | `commit-push:blocked` | CP-2 outcome is `gate_blocked` / `branch_mismatch` / `staging_incomplete` / `staging_check_failed` / `push_failed` / `conflict` / `bootstrap_pending` | outcome name + the workaround that worked | `-` |
| `commit_push` | E | `commit-push:pushed` | CP-2 outcome is `pushed` / `pr_created` / `pr_reused` | pushed branch (evidence no re-push is needed) | state `last_pushed_sha` |
