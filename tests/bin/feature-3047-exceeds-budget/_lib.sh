# shellcheck shell=bash
# tests/bin/feature-3047-exceeds-budget/_lib.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, budget, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared setup of tests/bin/feature-3047-exceeds-budget.sh: the feature-2431 helpers (TMPROOT,
# isolation, seed_failing, read_step_field, mk_fixture_repo), one driver fixture repo, and eb_drive,
# which runs a snippet in a child bash holding the CLI's libs (driver.sh).
# Sourced after tests/lib/harness.sh; never run standalone.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }
EB_2431_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline"
# shellcheck source=../feature-2431-run-tests-baseline/helpers.sh
. "$EB_2431_DIR/helpers.sh"
# shellcheck source=../feature-2431-run-tests-baseline/cli.sh
. "$EB_2431_DIR/cli.sh"

# Every budget and timeout knob a case depends on is the code's default unless a case pins it.
unset RTB_BUDGET_TOTAL RUN_ALL_TIMEOUT_SECONDS RUN_ALL_PARALLEL
mkdir -p "$TMPROOT/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"

EB_DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3047-exceeds-budget/driver.sh"
EB_RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

# eb_repo <dir> — main: tests/bin/t.sh and u.sh (both exit 1); feature: one more commit.
# Sets EB_B2 to main's commit. Checked out on feature.
eb_repo() {
  local r="$1"
  git init -q "$r"
  git -C "$r" config core.hooksPath /dev/null
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name T
  git -C "$r" config commit.gpgsign false
  git -C "$r" config core.autocrlf false
  git -C "$r" symbolic-ref HEAD refs/heads/main
  mkdir -p "$r/tests/bin"
  printf '#!/usr/bin/env bash\n# t\nexit 1\n' >"$r/tests/bin/t.sh"
  printf '#!/usr/bin/env bash\n# u\nexit 1\n' >"$r/tests/bin/u.sh"
  git -C "$r" add -A; git -C "$r" commit -q -m base
  EB_B2="$(git -C "$r" rev-parse HEAD)"
  git -C "$r" checkout -q -b feature
  printf 'head\n' >"$r/head.txt"
  git -C "$r" add -A; git -C "$r" commit -q -m feature
}

# eb_drive <cache> <snippet> [VAR=val...] — the snippet runs in driver.sh against EB_REPO; sets
# EB_OUT (stdout+stderr) and EB_RC. <cache> is this case's own RUN_ALL_CACHE_DIR (duration ledger,
# branch cache, baseline ledger), so a second call on the same <cache> sees the first one's rows.
eb_drive() {
  local cache="$1" snippet="$2"; shift 2
  mkdir -p "$cache"
  EB_RC=0
  EB_OUT="$(cd "$TMPROOT" && env RUN_ALL_CACHE_DIR="$(np "$cache")" EB_B2="$EB_B2" "$@" \
    bash "$EB_RWT" 60 bash "$EB_DRIVER" "$(np "$EB_REPO")" "$snippet" 2>&1)" || EB_RC=$?
}

# eb_line <prefix> — the first EB_OUT line containing <prefix>, or "(none)".
eb_line() {
  local l
  l="$(printf '%s\n' "$EB_OUT" | grep -m 1 -F -- "$1")" || l="(none)"
  printf '%s' "$l"
}

# eb_tail — the last 800 bytes of EB_OUT, so a failure message shows the end of the run, not all of it.
eb_tail() { if [ "${#EB_OUT}" -gt 800 ]; then printf '%s' "${EB_OUT: -800}"; else printf '%s' "$EB_OUT"; fi; }
eb_ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want=[$2] got=[$3]; rc=$EB_RC out(tail): $(eb_tail)"; fi; }
eb_has() { case "$EB_OUT" in *"$2"*) pass "$1" ;; *) fail "$1: missing [$2] in (tail): $(eb_tail)" ;; esac; }
eb_lacks() { case "$EB_OUT" in *"$2"*) fail "$1: unexpected [$2] in (tail): $(eb_tail)" ;; *) pass "$1" ;; esac; }
eb_match() { if printf '%s\n' "$EB_OUT" | grep -qE -- "$2"; then pass "$1"; else fail "$1: no line matches /$2/ in (tail): $(eb_tail)"; fi; }

# The stderr lines S4-5 fixes (detail plan); <t> is a regex-escaped test path.
eb_exceeds_line() { printf 'run-tests-baseline: exceeds budget: %s measured %ss > %ss per call; auto-accepted, listed under Unverified tests' "$1" "$2" "$3"; }
eb_no_measure_re() {
  printf '^run-tests-baseline: budget-exhausted: %s has no completed measurement \\(%s\\); let /run-tests run it to completion, or fix it if it hangs$' "$1" "$2"
}
