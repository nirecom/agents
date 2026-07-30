---
name: run-tests
description: Runs the test suite through the test-runner worker and emits the run_tests workflow sentinel. Used by Workflow Step 6.
tools: Bash, Write
model: sonnet
user-invocable: false
---

Run the project test suite via the `test-runner` worker and emit the workflow sentinel.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via supervisor-report — see rules/supervisor-reporting.md.

RNT-1. **merge-base を解決する。**
   `bin/select-tests.sh --auto` が `bin/resolve-merge-base.sh` 経由で解決する — このスキルは連鎖を再実装しない。
   exit 4（SUSPECT / FALLBACK / ヘルパー不在）→ 停止し、`bin/resolve-merge-base.sh --explain` の stderr 出力をそのまま提示して、採用する base をユーザーに選ばせる（候補の sha / 任意の sha / 安全側の `HEAD` / 中止）。
   ユーザーが base を確定したら `bin/workflow/record-merge-base-baseline --session <sid> --base <sha> --reason "<確認内容>"` で記録し、RNT-1 を再実行する（以後は RECORDED として通る）。
   中止を選ばれたら RNT-9 の pending sentinel を出して終了する。
   exit 0 で stdout が空 → 空選択として RNT-5 の方針に従う。

RNT-2. **Tier 1 — mechanical stem match.**
   `tier1_tests=$(bin/select-tests.sh --auto)`
   Filename stem substring match only. No frontmatter reading.

RNT-3. **Tier 2 — LLM semantic match.**
   `merge_base=$(bin/resolve-merge-base.sh --format base)` — RNT-1 と同じ base が返るので Tier 1 と Tier 2 の対象範囲は一致する。
   For each `tests/*.sh` not in `tier1_tests` and not under `tests/_archive/`:
   - Read `# Tests:` and `# Tags:` lines (single-line, within `head -n 10`).
   - Compare against `git diff --name-only "$merge_base"...HEAD` and diff body.
   - Add if: `# Tests:` path overlaps a changed file, OR `# Tags:` token semantically matches a changed subsystem.
   - Cap: max 20 Tier 2 additions per run.

RNT-4. **Tier 3 — default skip.**
   All remaining tests are skipped unless `RUN_ALL_TESTS=1` or `--all` is passed explicitly.

RNT-5. **Empty-selection policy (no silent `--all` fallback).**
   If Tier 1 + Tier 2 = 0 tests:
   - Docs-only change (all changed files match the docs allowlist): log `[run-tests] docs-only change; skipping tests` and skip.
   - Otherwise: log `[run-tests] no tests matched; user judgment required` and ask the user: skip / `--all` (explicit opt-in) / specify tests. Never auto-fallback to `--all` — that recreates the #673 hang.

RNT-6. **Run tests.**
   Pass the final list as positional args to `tests/run-all.sh`. Use `tests/run-all.sh --all` only when the user explicitly opts in. Never pass `auto-detect`.

RNT-7. **Dispatch `test-runner`** per `skills/_shared/worker-dispatch.md`. Payload: `cwd` (worktree the tests run in), `test_args` (the RNT-6 list, or `["--all"]` on explicit opt-in), `timeout_seconds` (omit for the 120s default).

RNT-8. **Parse the YAML** the dispatch call printed on stdout.

RNT-9. **Emit sentinel** as a separate Bash call:
   - `status: pass` → `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
   - `status: fail | timeout | runner-error` → `echo "<<WORKFLOW_MARK_STEP_run_tests_pending>>"`
   - 失敗が当該差分と無関係な既存失敗であることを示せる場合に限り、外科的復旧として `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"` を使う。
     根拠を同一ターンで提示する: 失敗テスト名 / 失敗が触れているパス / それが `bin/resolve-merge-base.sh --format base` を基点とした差分に含まれないこと / main でも同じ失敗が再現すること。
     根拠を提示できないときは使わない。`pending` のままユーザーに判断を委ねる。
     この目的で `WORKFLOW_ENFORCE_WORKFLOW_OFF` / EMERGENCY OFF を使ってはならない。単一ステップの復旧に session-wide の enforcement 解除は不要かつ過剰である。

RNT-10. If status is not `pass`, surface: `summary` / `failing_tests` / `log_tail`.

## Rules

- Test selection is this skill's responsibility, not test-runner's. Never pass `auto-detect`.
- Always pass an explicit list or `--all` to `tests/run-all.sh`.
- Empty selection on non-doc changes requires user confirmation; no silent `--all` fallback.
- merge-base の解決連鎖をこのスキル内に再実装しない（SSOT: bin/resolve-merge-base.sh）。
- 無関係な既存失敗の復旧は run_tests 単一ステップの完了マークに限る。session-wide の OFF sentinel を代替に使わない。
- Never modify source code or test files.
- Never retry on failure (Phase 1 only).
- Report observations per rules/supervisor-reporting.md.
