# shellcheck shell=bash
# tests/bin/feature-3047-exceeds-budget/cli.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, timeout, budget, scope:issue-specific, pwsh-not-required, TL2
# T2/T3 through the real bin/run-tests-baseline: the branch stage is a cache hit
# (timeout-after-540s rows), and SECONDS=530 in the environment leaves the base 23 s
# (600-45-530-2 < RTB_BUDGET_MIN_SLICE), so every test meets the base's budget-0 exit. The duration
# ledger is seeded with run-all.sh's writer functions and must be byte-identical after the call.
# Sourced by the entrypoint after _lib.sh; one function per case.

# eb_cli_body <name> — a test that fails the same way on main and on the branch, with no case records.
eb_cli_body() { printf '#!/usr/bin/env bash\n# %s\nexit 1\n' "$1"; }

# eb_cli_build <repo> — the 2431 fixture plus tests/bin/t-x.sh, t-y.sh, t-z.sh on main, merged into feature.
eb_cli_build() {
  local repo="$1" n
  mk_fixture_repo "$repo" >/dev/null || return 1
  git -C "$repo" checkout -q main
  for n in x y z; do eb_cli_body "$n" >"$repo/tests/bin/t-$n.sh"; done
  chmod +x "$repo/tests/bin/"t-*.sh
  git -C "$repo" add -A; git -C "$repo" commit -q -m "exceeds-budget base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
}

# eb_cli_rewrite_rows <cache> <result> — every branch cache row gets <result> and fp `-`.
eb_cli_rewrite_rows() {
  local seg n=0
  for seg in "$1"/branch.v2.*.seg; do
    [ -f "$seg" ] || continue
    awk -F'\t' -v OFS='\t' -v res="$2" 'NF >= 6 { $5 = res; $6 = "-" } { print }' "$seg" >"$seg.tmp" \
      && mv "$seg.tmp" "$seg" && n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# eb_cli_seed <cache> <repo> <rel> <secs> <STATE>... — duration rows through run-all.sh's writer.
eb_cli_seed() {
  local cache="$1" repo="$2"; shift 2
  (cd "$repo" && export RUN_ALL_CACHE_DIR="$(np "$cache")" && run_with_timeout 30 bash -c '
. "$1" || exit 98
root="$(git -C "$2" rev-parse --show-toplevel)" || exit 97
shift 2
run_all_dur_writer_init "$root"
[ "$RUN_ALL_DUR_WRITE_OK" = 1 ] || exit 96
while [ "$#" -ge 3 ]; do
  run_all_dur_key_into "$root/$1" "$root" || exit 95
  run_all_dur_file_result_into "$3"
  run_all_dur_append "$RUN_ALL_DUR_KEY_OUT" "$2" "$RUN_ALL_DUR_FR_VERDICT" "$RUN_ALL_DUR_FR_TERM"
  shift 3
done' eb_cli_seed "$LEDGER_LIB" "$repo" "$@")
}

# eb_cli_snapshot <cache> — every duration file with its bytes, for a byte-level before/after compare.
eb_cli_snapshot() {
  local f
  for f in "$1"/durations/*; do
    [ -f "$f" ] || continue
    printf '== %s\n' "${f##*/}"; od -An -tx1 "$f"
  done
}

# eb_cli_run <cache> <repo> <sid> — the CLI with SECONDS=530 in its environment (no explicit timeout).
eb_cli_run() {
  RTB_CLI_RC=0
  RTB_CLI_OUT="$(cd "$TMPROOT" && export RUN_ALL_CACHE_DIR="$1" && run_with_timeout 120 \
    env SECONDS=530 bash "$BASELINE_CLI" --session "$3" --worktree "$2" 2>&1)" || RTB_CLI_RC=$?
}

eb_cli_note() {
  run_with_timeout 15 node -e 'const m = require(process.argv[1] + "/hooks/lib/run-tests-completion-note.js"); process.stdout.write(m.readCompletionNote(process.argv[2]) || "");' \
    "$AGENTS_WIN" "$1" 2>/dev/null
}

# eb_cli_setup — run 1 records branch rows; they become timeout-after-540s hits; the baseline ledger
# and duration ledger are cleared and the durations seeded (t-x 927 completed, t-y 400 timeout,
# t-z 500 completed).
eb_cli_setup() {
  EB_CLI_REPO="$TMPROOT/repo-cli"
  EB_CLI_CACHE="$(cli_case_cache eb)"
  eb_cli_build "$EB_CLI_REPO" || { fail "fixture: CLI repo not built"; return 1; }
  seed_failing "eb0-$$" tests/bin/t-x.sh tests/bin/t-y.sh tests/bin/t-z.sh
  rtb_cli_run "$EB_CLI_CACHE" "$EB_CLI_REPO" "eb0-$$" --per-test-timeout 20
  if eb_cli_rewrite_rows "$EB_CLI_CACHE" "timeout-after-540s"; then
    pass "setup: run 1 left branch cache rows, now timeout-after-540s"
  else
    fail "setup: no branch cache rows to rewrite; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  rm -rf "$EB_CLI_CACHE/baseline" "$EB_CLI_CACHE/durations"
  if eb_cli_seed "$EB_CLI_CACHE" "$EB_CLI_REPO" tests/bin/t-x.sh 927 FAIL tests/bin/t-y.sh 400 TIMEOUT tests/bin/t-z.sh 500 FAIL; then
    pass "setup: duration ledger seeded through run_all_dur_append"
  else
    fail "setup: duration ledger seeding failed"
  fi
}

# T2: t-x measured 927 s completed meets the base's budget-0 exit.
eb_cli_exceeds() {
  local before after note
  before="$(eb_cli_snapshot "$EB_CLI_CACHE")"
  seed_failing "eba-$$" tests/bin/t-x.sh
  eb_cli_run "$EB_CLI_CACHE" "$EB_CLI_REPO" "eba-$$"
  after="$(eb_cli_snapshot "$EB_CLI_CACHE")"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "BASELINE: undetermined tests/bin/t-x.sh exceeds-budget" && [ "$RTB_CLI_RC" -eq 0 ]; then
    pass "T2: budget 0 at base with a completed 927 s measurement is exceeds-budget, exit 0"
  else
    fail "T2: want 'BASELINE: undetermined tests/bin/t-x.sh exceeds-budget' and exit 0; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qF "run-tests-baseline: exceeds budget: tests/bin/t-x.sh measured 927s > 553s per call"; then
    pass "T2: stderr names 927s > 553s (the real base limit, reserve 0)"
  else
    fail "T2: no 'exceeds budget: ... 927s > 553s' line in: $RTB_CLI_OUT"
  fi
  note="$(eb_cli_note "eba-$$")"
  if printf '%s\n' "$note" | grep -E '^- Unverified tests: ' | grep -qF 'exceeds-budget'; then
    pass "T2: the completion note's Unverified tests causes name exceeds-budget"
  else
    fail "T2: no exceeds-budget cause in the completion note: [$note]"
  fi
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    pass "T2: the duration ledger is byte-identical before and after the CLI (baseline never writes it)"
  else
    fail "T2: the duration ledger changed (or was empty) across the CLI call"
  fi
}

# T3 (CLI): a timeout-only row and a completed measurement within the limit stay budget-exhausted.
eb_cli_budget_exhausted() {
  seed_failing "ebb-$$" tests/bin/t-y.sh tests/bin/t-z.sh
  eb_cli_run "$EB_CLI_CACHE" "$EB_CLI_REPO" "ebb-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "BASELINE: undetermined tests/bin/t-y.sh budget-exhausted"; then
    pass "T3: a timeout-only measurement stays budget-exhausted"
  else
    fail "T3: want t-y.sh budget-exhausted; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "BASELINE: undetermined tests/bin/t-z.sh budget-exhausted"; then
    pass "T3: a completed 500 s measurement within 553 s stays budget-exhausted"
  else
    fail "T3: want t-z.sh budget-exhausted; rc=$RTB_CLI_RC ($(cli_baseline_lines))"
  fi
  if [ "$RTB_CLI_RC" -eq 8 ]; then pass "T3: budget-exhausted requests a re-run (exit 8)"
  else fail "T3: want exit 8, got $RTB_CLI_RC"; fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE '^run-tests-baseline: budget-exhausted: tests/bin/t-y\.sh has no completed measurement \([^)]*\); let /run-tests run it to completion, or fix it if it hangs$'; then
    pass "T3: stderr says t-y.sh has no completed measurement"
  else
    fail "T3: no 'has no completed measurement' line for t-y.sh in: $RTB_CLI_OUT"
  fi
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE 'exceeds budget: |budget-exhausted: tests/bin/t-z\.sh has no completed'; then
    fail "T3: an exceeds-budget or no-completed-measurement line was printed for t-y/t-z: $RTB_CLI_OUT"
  else
    pass "T3: no exceeds-budget line, and none for the within-limit t-z.sh"
  fi
}

# #3035 S2-5: when a js branch run times out in the real CLI, the cache row gets the language cap of 180s.
# The fixture launcher (<wt>/bin/lib/run-all-launch.sh, which rtb_exec_one prefers) returns TIMEOUT immediately.
# If the CLI does not call tlr_load before the branch stage, the cap cannot be looked up and the row becomes timeout-after-300s.
eb_cli_lang_cap() {
  local repo="$TMPROOT/repo-cli-js" cache sid="ebjs-$$" row
  cache="$(cli_case_cache eb-js)"
  mk_fixture_repo "$repo" >/dev/null || { fail "fixture: js repo not built"; return 1; }
  git -C "$repo" checkout -q main
  printf '// fixture js test for #3035\nprocess.exit(1);\n' >"$repo/tests/bin/j.js"
  mkdir -p "$repo/bin/lib"
  printf 'run_all_exec() { RUN_ALL_EXEC_LAUNCHED=1; RUN_ALL_EXEC_STATE=TIMEOUT; return 124; }\n' \
    >"$repo/bin/lib/run-all-launch.sh"
  git -C "$repo" add -A; git -C "$repo" commit -q -m "js test and timing-out launcher"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  seed_failing "$sid" tests/bin/j.js
  RTB_CLI_RC=0
  RTB_CLI_OUT="$(cd "$TMPROOT" && export RUN_ALL_CACHE_DIR="$cache" && run_with_timeout 120 \
    bash "$BASELINE_CLI" --session "$sid" --worktree "$repo" 2>&1)" || RTB_CLI_RC=$?
  row="$(awk -F'\t' '$4 == "tests/bin/j.js" { print $5 }' "$cache"/branch.v2.*.seg 2>/dev/null | tail -n 1)"
  if [ "$row" = "timeout-after-180s" ]; then
    pass "S2-5: the real CLI records the js branch timeout at the registry cap (timeout-after-180s)"
  else
    fail "S2-5: want branch cache row timeout-after-180s for tests/bin/j.js, got [${row:-(none)}]; rc=$RTB_CLI_RC out: $RTB_CLI_OUT"
  fi
}
