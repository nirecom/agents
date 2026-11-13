# shellcheck shell=bash
# tests/bin/feature-2956-baseline-compare-cli/_lib.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, compare, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared setup of the tests/bin/feature-2956-baseline-compare-cli*.sh entrypoints (#2956 S4/S8).
# Each fixture test is unchanged between base and branch and replays records from
# cmpdata/<name>.tsv, a file outside its data dir, so only the records differ. The suite is split
# into several entrypoints because one CLI run costs seconds per test on Windows.
# Sourced after tests/lib/harness.sh; never run standalone.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }
CMP_SUBDIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline"
# shellcheck source=../feature-2431-run-tests-baseline/helpers.sh
. "$CMP_SUBDIR/helpers.sh"
# shellcheck source=../feature-2431-run-tests-baseline/cli.sh
. "$CMP_SUBDIR/cli.sh"

COMPARE_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-compare.sh"
NEWL="fails-at-base-exit-1-new-lines"

# cmp_test_body <name> — a failing test that replays cmpdata/<name>.tsv into the result dir:
# `C<TAB>seq<TAB>case` gives a FAIL case record, `D<TAB>seq<TAB>case<TAB>text` a detail record.
cmp_test_body() {
  printf '#!/usr/bin/env bash\nsrc="$(dirname "$0")/../../cmpdata/%s.tsv"\n' "$1"
  cat <<'BODY'
d="${RUN_ALL_RESULT_DIR:-}"
if [ -n "$d" ] && [ -f "$src" ]; then
  while IFS=$'\t' read -r k a b c; do
    case "$k" in
      C) printf '%s\tFAIL\t%s\t-\n' "$a" "$b" >>"$d/cases.tsv" ;;
      D) printf '%s\t%s\t%s\n' "$a" "$b" "$c" >>"$d/fail-details.tsv" ;;
    esac
  done <"$src"
fi
exit 1
BODY
}

# cmp_fail <data-file> <seq> <case> <text>... — one FAIL case and one detail record per text.
cmp_fail() {
  local f="$1" seq="$2" c="$3" t; shift 3
  printf 'C\t%s\t%s\n' "$seq" "$c" >>"$f"
  for t in "$@"; do printf 'D\t%s\t%s\t%s\n' "$seq" "$c" "$t" >>"$f"; done
}

# cmp_write_side <repo> base|branch — every shape's records for one side (text already folded).
# A shape whose test the entrypoint does not create leaves an unread data file.
cmp_write_side() {
  local r="$1/cmpdata" side="$2" long
  rm -rf "$r"; mkdir -p "$r"
  printf -v long '%8192s' ''; long="${long// /z}\\n[cut]"
  if [ "$side" = base ]; then
    cmp_fail "$r/same.tsv" 1 case-a "violation X in tests/bin/t-same.sh:12 after 35ms"
    cmp_fail "$r/addv.tsv" 1 case-a "violation X"
    cmp_fail "$r/count.tsv" 1 case-a "leftover files [count=5]"
    cmp_fail "$r/list.tsv" 1 case-a "residue [list total=3: a | b | c]"
    cmp_fail "$r/cutlist.tsv" 1 case-a "residue [list total=5: a | b | c]"
    cmp_fail "$r/port.tsv" 1 case-a "connect example.com:8080 refused"
    cmp_fail "$r/multi.tsv" 1 case-a 'head line\nviolation A'
    cmp_fail "$r/ren.tsv" 1 case-a "bad call in lib/old-name.sh:3"
    cmp_fail "$r/brmiss.tsv" 1 case-a "violation X"
    cmp_fail "$r/changed.tsv" 1 case-a "violation X"
  else
    cmp_fail "$r/same.tsv" 1 case-a "violation X in tests/bin/t-same.sh:40 after 120ms"
    cmp_fail "$r/addv.tsv" 1 case-a "violation X" "violation Y"
    cmp_fail "$r/count.tsv" 1 case-a "leftover files [count=3]"
    cmp_fail "$r/list.tsv" 1 case-a "residue [list total=2: a | c]"
    cmp_fail "$r/cutlist.tsv" 1 case-a "residue [list total=4: a | b]"
    cmp_fail "$r/port.tsv" 1 case-a "connect example.com:9090 refused"
    cmp_fail "$r/multi.tsv" 1 case-a 'head line\nviolation A\nviolation B'
    cmp_fail "$r/ren.tsv" 1 case-a "bad call in lib/new-name.sh:3"
    cmp_fail "$r/basemiss.tsv" 1 case-a "violation X"
    printf 'D\t0\t-\tstray failure outside any case\n' >>"$r/outside.tsv"
    # A changed test file whose branch run adds a line: still a file verdict, but disclosed.
    cmp_fail "$r/changed.tsv" 1 case-a "violation X" "violation Z"
  fi
  cmp_fail "$r/cut.tsv" 1 case-a "$long"
  cmp_fail "$r/outside.tsv" 1 case-a "violation X"
}

# cmp_build_repo <repo> <name>... — main gains tests/bin/t-<name>.sh and the base records; feature
# changes only the records, renames lib/old-name.sh, and edits t-changed.sh when it exists.
cmp_build_repo() {
  local repo="$1" n; shift
  mk_fixture_repo "$repo" >/dev/null || return 1
  git -C "$repo" checkout -q main
  mkdir -p "$repo/lib"
  printf '#!/usr/bin/env bash\n# a library the rename shape moves\nlib_fn() {\n  echo one\n  echo two\n}\n' >"$repo/lib/old-name.sh"
  for n in "$@"; do cmp_test_body "$n" >"$repo/tests/bin/t-$n.sh"; done
  chmod +x "$repo/tests/bin/"t-*.sh
  cmp_write_side "$repo" base
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "compare base"
  git -C "$repo" checkout -q feature
  git -C "$repo" merge -q --no-edit main
  cmp_write_side "$repo" branch
  git -C "$repo" mv lib/old-name.sh lib/new-name.sh
  [ ! -f "$repo/tests/bin/t-changed.sh" ] || printf '# branch edit\n' >>"$repo/tests/bin/t-changed.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "compare branch"
}

# cmp_run <label> <name>... — one fixture repo, one session failing every t-<name>.sh, one CLI run
# (one base worktree); sets RTB_CLI_RC and RTB_CLI_OUT.
cmp_run() {
  local label="$1" repo="$TMPROOT/repo-$1" n; shift
  local -a tests=()
  cmp_build_repo "$repo" "$@" || fail "fixture: $label repo not built"
  for n in "$@"; do tests+=("tests/bin/t-$n.sh"); done
  seed_failing "$label-$$" "${tests[@]}"
  rtb_cli_run "$(cli_case_cache "$label")" "$repo" "$label-$$" --per-test-timeout 20
}

# cmp_expect <label> <ERE after "BASELINE: "> — one BASELINE line matches.
cmp_expect() {
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: $2"; then pass "$1"
  else fail "$1: no 'BASELINE: $2' line; rc=$RTB_CLI_RC ($(cli_baseline_lines))"; fi
}

# cmp_expect_pre <label> <name> — t-<name>.sh is preexisting (a proof).
cmp_expect_pre() { cmp_expect "$1" "preexisting[[:space:]]+tests/bin/t-$2\.sh([[:space:]]|\$)"; }

# cmp_expect_new <label> <name> <head-fragment> — (c) with one new line whose text reaches the head.
cmp_expect_new() {
  local line
  line="$(printf '%s\n' "$RTB_CLI_OUT" | grep -E "^BASELINE: new-case-failure-on-branch tests/bin/t-$2\.sh $NEWL new=1 head=\[" | head -n 1)"
  if [ -n "$line" ] && printf '%s' "$line" | grep -qF -- "$3"; then pass "$1"
  else fail "$1: expected new-case-failure-on-branch t-$2.sh $NEWL new=1 head with '$3'; rc=$RTB_CLI_RC ($(cli_baseline_lines))"; fi
}

# cmp_expect_summary <label> <rc> <pre> <file_verdict> <new_on_branch> — the exact summary and exit.
cmp_expect_summary() {
  local want; want="$(baseline_summary "$3" 0 0 0 "$4" "$5")"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qxF "$want" && [ "$RTB_CLI_RC" -eq "$2" ]; then pass "$1"
  else fail "$1: expected '$want' and exit $2; rc=$RTB_CLI_RC ($(cli_baseline_lines))"; fi
}
