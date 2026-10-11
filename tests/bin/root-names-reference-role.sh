#!/usr/bin/env bash
# Tests: bin/check-root-names/reference-role.js, bin/check-root-names/main.js
# Tags: root-names, reference-role, classifier, table-driven, gate, static-check, bin, scope:issue-specific, TL2
# #2589 (commit 9 of #2561): the reference-role check judges each occurrence whose role
# the syntax decides — a self-path definition, a main-worktree definition, a checkout
# definition, a config read — against the one name that fits the role. An occurrence
# whose role is not decided passes this check and stays with the file's table rule.
# TL3 gap (what this test does NOT catch):
# - the count of existing tree occurrences the new check reports (S9-6 measures it).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

# The message text of the check is not fixed by the plan, so only the check name and
# the line are asserted.
msg_of() { printf ''; }

# The plan's main-worktree marker is itself on the retired-name list, so it is split.
MWO="mainWorktree""Of"

# names <var> — replace the @SCR@/@AMR@/@TMR@/@TCR@ placeholders in the variable, so
# this file never carries a line the gate itself would judge.
names() {
  local v="${!1}"
  v="${v//@SCR@/$N_SCR}"
  v="${v//@AMR@/$N_AMR}"
  v="${v//@TMR@/$N_TMR}"
  v="${v//@TCR@/$N_TCR}"
  v="${v//@MWO@/$MWO}"
  printf -v "$1" '%s' "$v"
}

# Columns: <path>|<verdict>|<content>. bad@<n> = reported on line n; accepted = no line.
# tests/** allows all four names, so the file rule never hides a wrong role.
table BAD_ROWS <<'TABLE'
tests/r-self-tmr.sh|bad@1|@TMR@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests/r-self-amr.sh|bad@1|@AMR@="$(cd "$(dirname "$0")/../.." && pwd)"
tests/r-self-tcr.js|bad@1|const @TCR@ = path.resolve(__dirname, "..");
tests/r-self-tmr.ps1|bad@1|$@TMR@ = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
tests/r-main-scr.sh|bad@1|@SCR@="$(git worktree list --porcelain | head -n 1)"
tests/r-main-amr.sh|bad@1|@AMR@="$(git rev-parse --git-common-dir)"
tests/r-main-tool.sh|bad@1|@SCR@="$(bash bin/main-worktree-root)"
tests/r-main-tcr.js|bad@1|const @TCR@ = @MWO@(dir);
tests/r-main-tcr-multiline.js|bad@1|const @TCR@ =<NL>  @MWO@(dir);
tests/r-top-tmr.sh|bad@1|@TMR@="$(git rev-parse --show-toplevel)"
bin/r-top-scr.sh|bad@1|@SCR@="$(git rev-parse --show-toplevel)"
tests/r-top-second.sh|bad@2|#!/usr/bin/env bash<NL>@AMR@="$(git -C "$d" rev-parse --show-toplevel)"
tests/r-cfg-scr.sh|bad@1|. "$@SCR@/.env"
tests/r-cfg-tmr.sh|bad@1|cat "$@TMR@/.env.local"
tests/r-cfg-tcr.sh|bad@1|grep x "$@TCR@/docs/private-info/hosts.md"
tests/r-cfg-scr.js|bad@1|const f = path.join(@SCR@, ".env");
TABLE
table GOOD_ROWS <<'TABLE'
tests/r-self-ok.sh|accepted|@SCR@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests/r-self-ok.js|accepted|const @SCR@ = path.resolve(__dirname, "..", "..");
tests/r-self-ok.ps1|accepted|$@SCR@ = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
bin/sourced/lib.sh|accepted|_LIB_@SCR@="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tests/r-main-ok.sh|accepted|@TMR@="$(git worktree list --porcelain | head -n 1)"
tests/r-main-ok.js|accepted|const @TMR@ = @MWO@(dir);
tests/r-top-ok.sh|accepted|@TCR@="$(git -C "$dir" rev-parse --show-toplevel)"
tests/r-cfg-ok.sh|accepted|. "$@AMR@/.env"
tests/r-cfg-ok.js|accepted|const f = path.join(@AMR@, ".env.local");
TABLE
# Occurrences whose role the syntax does not decide.
table OPEN_ROWS <<'TABLE'
tests/r-u-echo.sh|accepted|echo "$@TMR@"
tests/r-u-code-dir.sh|accepted|cd "$@TCR@/bin"
tests/r-u-arg.sh|accepted|@TMR@="$1"
tests/r-u-flag.sh|accepted|node tool.js --target-main-root "$@TMR@"
tests/r-u-pwd.sh|accepted|@TMR@="$(cd "$dir" && pwd)"
tests/r-u-envrc.sh|accepted|cat "$@SCR@/.envrc"
tests/r-u-comment.sh|accepted|# @TMR@="$(git rev-parse --show-toplevel)"
tests/r-u-tool.sh|accepted|bash "$@SCR@/bin/tool.sh"
TABLE
# Two definitions on one line: a fitting one first, then a wrong one. Only the second can
# be reported, so a report on line 1 proves the check looks past the first assignment.
table MULTI_ROWS <<'TABLE'
tests/r-multi-self.sh|bad@1|@SCR@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; @TMR@="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests/r-multi-top.sh|bad@1|@TCR@="$(git -C "$d" rev-parse --show-toplevel)"; @AMR@="$(git -C "$d" rev-parse --show-toplevel)"
tests/r-multi-self.js|bad@1|const @SCR@ = path.resolve(__dirname, ".."); const @TCR@ = path.resolve(__dirname, "..");
TABLE
names BAD_ROWS
names GOOD_ROWS
names OPEN_ROWS
names MULTI_ROWS

make_kit role
write_table "$KIT"
new_repo role
seed "$REPO" BAD_ROWS 1
seed "$REPO" GOOD_ROWS 1
seed "$REPO" OPEN_ROWS 1
seed "$REPO" MULTI_ROWS 1
fx "$REPO/plain/x.sh" "echo \"\$$N_TMR\""
commit_all "$REPO"

c_wrong_name_for_the_role() {
  run_gate "$KIT" --root "$REPO" --only reference-role
  expect "role: the check is known and finds a violation (exit 1)" rc_is 1
  expect_rows "wrong name" reference-role <<<"$BAD_ROWS"
}

c_fitting_name_passes() {
  run_gate "$KIT" --root "$REPO" --only reference-role
  expect_rows "fitting name" reference-role <<<"$GOOD_ROWS"
}

c_second_definition_on_a_line() {
  run_gate "$KIT" --root "$REPO" --only reference-role
  expect_rows "second definition" reference-role <<<"$MULTI_ROWS"
}

c_undecided_role_passes() {
  run_gate "$KIT" --root "$REPO" --only reference-role
  expect_rows "undecided role" reference-role <<<"$OPEN_ROWS"
}

# An undecided occurrence still meets the file rule: plain/** allows no name.
c_undecided_falls_back_to_the_file_rule() {
  run_gate "$KIT" --root "$REPO" --only reference-role
  expect "fallback: reference-role is silent on plain/x.sh" clean_for "plain/x.sh" reference-role
  run_gate "$KIT" --root "$REPO"
  expect "fallback: the table rule reports plain/x.sh" reports "plain/x.sh" table-match 1 'is not allowed'
  expect "fallback: a run with no check named includes reference-role" reports "tests/r-self-tmr.sh" reference-role 1
}

case_begin "wrong-name-for-each-role-is-reported" "bin/check-root-names/reference-role.js"
c_wrong_name_for_the_role
case_end

case_begin "fitting-name-for-each-role-passes" "bin/check-root-names/reference-role.js"
c_fitting_name_passes
case_end

case_begin "wrong-second-definition-on-a-line-is-reported" "bin/check-root-names/reference-role.js"
c_second_definition_on_a_line
case_end

case_begin "occurrence-without-a-decided-role-passes" "bin/check-root-names/reference-role.js"
c_undecided_role_passes
case_end

case_begin "undecided-occurrence-falls-back-to-the-file-rule" "bin/check-root-names/main.js"
c_undecided_falls_back_to_the_file_rule
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
