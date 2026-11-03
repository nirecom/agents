# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/stage-order.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, stage-order, rerun-request, note, scope:issue-specific, pwsh-not-required, TL2
# #2688 — stage order (branch -> base), the exit 8 re-run request, --note passthrough, removal of the user grant.
# Sourced by the dispatcher after helpers.sh; never run standalone.

: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

so_ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want=[$2] got=[$3]"; fi; }
so_has() { case "$RTB_CLI_OUT" in *"$2"*) pass "$1" ;; *) fail "$1 — missing [$2] in: $RTB_CLI_OUT" ;; esac; }
so_lacks() { case "$RTB_CLI_OUT" in *"$2"*) fail "$1 — unexpected [$2] in: $RTB_CLI_OUT" ;; *) pass "$1" ;; esac; }

# so_repo <dir> — tests/bin/t.sh at main@base creates a base marker and exits 77 (skip-at-base).
# The same test at feature@HEAD creates a branch marker and exits 1 (fails alone too). Markers live in <dir>.marks.
so_repo() {
  local repo="$1" m
  mkdir -p "$repo.marks"
  m="$(np "$repo.marks")"
  git init -q "$repo"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin"
  printf '#!/usr/bin/env bash\ntouch "%s/base"\nexit 77\n' "$m" > "$repo/tests/bin/t.sh"
  chmod +x "$repo/tests/bin/t.sh"
  git -C "$repo" add tests
  git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b feature
  printf '#!/usr/bin/env bash\ntouch "%s/branch"\nexit 1\n' "$m" > "$repo/tests/bin/t.sh"
  git -C "$repo" add tests
  git -C "$repo" commit -q -m head
}

run_cli_stage_order_cases() {
  local help repo sid cache

  # --help describes exit 8 and --note, and does not describe the grant output.
  help="$(run_with_timeout 20 bash "$BASELINE_CLI" --help 2>&1)"
  # Exit 8 must appear in the Exit: list as "8 <re-run description>" (a bare digit 8 match is not enough).
  # --help prints the header "# Exit:" line and its indented continuation lines; inspect only that range.
  printf '%s\n' "$help" | awk '/^# *Exit:/ { on = 1; print; next } on && /^#   +/ { print; next } { on = 0 }' \
    | grep -Eiq '(Exit:|[ ,(])8 [^,]*re-?run' \
    && pass "help: the Exit list names exit 8 as a re-run request" \
    || fail "help: the Exit list names exit 8 as a re-run request — $help"
  case "$help" in *--note*) pass "help: names --note" ;; *) fail "help: names --note — $help" ;; esac
  case "$help" in *BASELINE_ACCEPTED*) fail "help: drops BASELINE_ACCEPTED — $help" ;; *) pass "help: drops BASELINE_ACCEPTED" ;; esac

  # --note without a value is a usage error (exit 2).
  RTB_CLI_RC=0
  run_with_timeout 20 bash "$BASELINE_CLI" --session "so-usage-$$" --note >/dev/null 2>&1 || RTB_CLI_RC=$?
  so_ck "usage: --note without a value exits 2" 2 "$RTB_CLI_RC"

  # Fails alone, then skip-at-base on base, then auto-accepted. --note reaches baseline_note.
  repo="$TMPROOT/so-note"; sid="so-note-$$"; cache="$TMPROOT/so-note.cache"; mkdir -p "$cache"
  so_repo "$repo"
  seed_failing "$sid" tests/bin/t.sh
  rtb_cli_run "$cache" "$repo" "$sid" --per-test-timeout 10 --note "seen skipped on main"
  so_ck "note: exit 0 (auto-accepted)" 0 "$RTB_CLI_RC"
  [ -e "$repo.marks/branch" ] && pass "order: the branch copy ran first" || fail "order: the branch copy ran first"
  [ -e "$repo.marks/base" ] && pass "order: then the base copy ran" || fail "order: then the base copy ran"
  so_has "note: RECORDED line names the auto basis" "RECORDED completion_basis=baseline-auto-accepted"
  so_ck "note: completion_basis" '"baseline-auto-accepted"' "$(read_step_field "$sid" run_tests completion_basis)"
  so_ck "note: baseline_note" '"seen skipped on main"' "$(read_step_field "$sid" run_tests baseline_note)"

  # Budget slice 0: neither the alone re-run nor base runs; a re-run request (exit 8) leaves it pending.
  repo="$TMPROOT/so-budget"; sid="so-budget-$$"; cache="$TMPROOT/so-budget.cache"; mkdir -p "$cache"
  so_repo "$repo"
  seed_failing "$sid" tests/bin/t.sh
  export RTB_BUDGET_TOTAL=50
  rtb_cli_run "$cache" "$repo" "$sid" --per-test-timeout 10
  unset RTB_BUDGET_TOTAL
  so_ck "rerun: budget exhaustion exits 8" 8 "$RTB_CLI_RC"
  so_has "rerun: budget-exhausted is reported" "budget-exhausted"
  so_ck "rerun: run_tests stays pending" '"pending"' "$(read_step_field "$sid" run_tests status)"

  # Even with an old grant annotation in state there is no step-0 acceptance; normal classification runs.
  repo="$TMPROOT/so-grant"; sid="so-grant-$$"; cache="$TMPROOT/so-grant.cache"; mkdir -p "$cache"
  so_repo "$repo"
  seed_failing "$sid" tests/bin/t.sh
  run_with_timeout 20 node -e 'require(process.argv[1] + "/hooks/workflow-state/state-io/events").appendEvents(process.argv[2], [{ kind: "step_annotation", step: "run_tests", key: "baseline_accept", value: { reason: "old", kind: "failing-list-unrecorded", run_seq: 1, outcome_source: null }, provenance: "declared", origin: "workflow-mark-run-tests-baseline-accept" }])' "$AGENTS_WIN" "$sid" >/dev/null 2>&1 \
    || fail "fixture: legacy grant annotation"
  rtb_cli_run "$cache" "$repo" "$sid" --per-test-timeout 10
  so_lacks "grant: no BASELINE_ACCEPTED line" "BASELINE_ACCEPTED"
  [ -e "$repo.marks/base" ] && pass "grant: the base copy still ran" || fail "grant: the base copy still ran"
  so_lacks "grant: no user-accepted basis" "baseline-user-accepted"
}
