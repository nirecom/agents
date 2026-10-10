#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/table-match.js
# Tags: root-names, table-match, classification, gate, static-check, bin, scope:issue-specific, TL2
# #2561: each tracked file may carry only the root names its classification
# rule allows; the four spellings of a name count as that name.
# TL3 gap (what this test does NOT catch):
# - the real classification table over the real tree; the scan test covers that.
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

# Spellings assembled from fragments: this file sits under tests/, yet it should
# read the same whichever rule ends up owning it.
CAMEL_TMR="target""MainRoot"
KEBAB_TCR="target-""checkout-root"
SNAKE_TMR="target_ma""in_root"
KEBAB_SCR="script-""checkout-root"
LOWER_SCR="script_""checkout_""root"
TABLE="bin/check-root-names/classification.json"
EXC_NAMED="{\"file\":\"bin/named.js\",\"allow\":[\"$N_AMR\"],\"forms\":[],\"reason\":\"fixture: named file\"}"
SRC_PATH="hooks/lib/$KEBAB_SCR.js"
EXC_SOURCE="{\"carrier\":\"resolveByPath()\",\"kind\":\"function\",\"source\":\"$SRC_PATH\",\"files\":[\"$SRC_PATH\",\"hooks/path-user.js\",\"hooks/path-other.js\"],\"reason\":\"fixture: source path\"}"

# The fixture rows (match_rows) and the message of each verdict key (msg_of).
. "$(dirname "$0")/feature-2561-root-names/table-match-rows.sh"

# next_row — read one fixture row into name / group / want / path / line and set
# class to reported or clean. Fails at the end of the table.
next_row() {
  while IFS='|' read -r name group want path line; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    group="${group//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    path="${path//[[:space:]]/}"
    line="${line# }"
    class=reported
    [[ "$want" == clean ]] && class=clean
    return 0
  done
  return 1
}

# has_row <group> <class> — the table holds at least one such row.
has_row() {
  local name group want path line class
  while next_row; do
    [[ "$group" == "$1" && "$class" == "$2" ]] && return 0
  done < <(match_rows)
  return 1
}

# seed_rows <group> <class>... — write the fixture file of each such row into $REPO.
seed_rows() {
  local pick="$1" name group want path line class
  shift
  while next_row; do
    [[ "$group" == "$pick" && " $* " == *" $class "* ]] || continue
    fx "$REPO/$path" "$line"
  done < <(match_rows)
}

# expect_table <group> <label> <class>... — one assertion per such row: a reported row
# names its line and its message, a clean row has no line of the check at all.
expect_table() {
  local pick="$1" label="$2" name group want path line class at
  shift 2
  while next_row <&3; do
    [[ "$group" == "$pick" && " $* " == *" $class "* ]] || continue
    if [[ "$class" == reported ]]; then
      at=1
      [[ "$want" == norule ]] && at=0
      expect "$label reported: $name ($path, $want)" reports "$path" table-match "$at" "$(msg_of "$want")"
    else
      expect "$label clean: $name ($path)" clean_for "$path" table-match
    fi
  done 3< <(match_rows)
}

c_allowed() {
  make_kit allowed
  write_table "$KIT" "$EXC_NAMED" "$EXC_SOURCE"
  new_repo allowed
  seed_rows rule clean
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "allowed: the table holds an accepted row" has_row rule clean
  expect "allowed: every file within its rule exits 0" rc_is 0
  expect_table rule "allowed" clean
}

c_disallowed() {
  make_kit disallowed
  write_table "$KIT" "$EXC_NAMED" "$EXC_SOURCE"
  new_repo disallowed
  seed_rows rule clean reported
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "disallowed: the table holds a rejected row" has_row rule reported
  expect "disallowed: exits 1" rc_is 1
  expect_table rule "disallowed" reported
  expect_table rule "disallowed, beside its neighbours" clean
}

c_carrier_kinds() {
  make_kit cross
  write_table "$KIT"
  new_repo cross
  seed_rows kinds reported clean
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "carrier: the table holds both verdicts" has_row kinds reported
  expect "carrier: the table holds an accepted row" has_row kinds clean
  expect "carrier: exits 1" rc_is 1
  expect_table kinds "carrier of another kind" reported clean
}

c_first_rule_wins() {
  make_kit order
  write_table "$KIT"
  new_repo order
  fx "$REPO/bin/special/two.sh" "echo \"\$$N_TMR\""
  fx "$REPO/bin/plain-two.sh" "echo \"\$$N_TMR\""
  fx "$REPO/skills/s/scripts/deep/x.sh" "echo \"$V_SCR\""
  fx "$REPO/skills/s/notes.md" "See $V_AMR."
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "order: exits 1" rc_is 1
  expect "order: the earlier, narrower rule allows the name" clean_for "bin/special/two.sh"
  expect "order: the later, wider rule does not" reports "bin/plain-two.sh" table-match 1 "$(msg_of tmr)"
  expect "order: a double-star glob spans directories" clean_for "skills/s/scripts/deep/x.sh"
  expect "order: the skills rule applies outside scripts" clean_for "skills/s/notes.md"
}

c_repo_switch() {
  make_kit repo
  write_table "$KIT"
  new_repo repo
  fx "$REPO/dot/only-dotfiles.sh" "echo \"$V_AMR\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match --repo dotfiles
  expect "repo: the dotfiles rules classify the dotfiles tree (exit 0)" rc_is 0
  run_gate "$KIT" --root "$REPO" --only table-match --repo agents
  expect "repo: the agents rules do not cover that file" \
    reports "dot/only-dotfiles.sh" table-match 0 "$(msg_of norule)"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "repo: agents is the default" reports "dot/only-dotfiles.sh" table-match 0 "$(msg_of norule)"
  fx "$REPO/bin/ok.sh" "echo \"$V_SCR\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match --repo dotfiles
  expect "repo: an agents-only path is unclassified under dotfiles" \
    reports "bin/ok.sh" table-match 0 "$(msg_of norule)"
  expect "repo: the dotfiles path stays clean" clean_for "dot/only-dotfiles.sh"
}

c_broken_table() {
  make_kit broken
  write_table "$KIT"
  new_repo broken
  fx "$REPO/bin/ok.sh" "echo \"$V_SCR\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "table: the intact table passes this tree (exit 0)" rc_is 0
  fx "$KIT/$TABLE" '{ "rules": [ this is not json'
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "table: unparsable JSON exits 2" rc_is 2
  fx "$KIT/$TABLE" '{"rules": "nope", "exceptions": []}'
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "table: a table of the wrong shape exits 2" rc_is 2
  fx "$KIT/$TABLE" '{"rules": [], "exceptions": []}'
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "table: an empty rule list leaves every file unclassified" \
    reports "bin/ok.sh" table-match 0 "$(msg_of norule)"
  rm -f "$KIT/$TABLE"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "table: a missing table exits 2" rc_is 2
}

c_empty_tree() {
  make_kit empty
  write_table "$KIT"
  new_repo empty
  fx "$REPO/plain/none.txt" ''
  fx "$REPO/plain/only-text.txt" 'root, checkout and target as plain words'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "empty: files without any root name exit 0" rc_is 0
}

c_rerun_stable() {
  make_kit rerun
  write_table "$KIT" "$EXC_NAMED" "$EXC_SOURCE"
  new_repo rerun
  seed_rows rule clean reported
  commit_all "$REPO"
  expect_rerun_stable "rerun" 1 "$REPO" "$KIT" --root "$REPO" --only table-match
}

c_hostile_text() {
  make_kit hostile
  write_table "$KIT"
  new_repo hostile
  fx "$REPO/bin/\$(touch PWNED_A).sh" "echo \"$V_AMR\""
  fx "$REPO/bin/a b;touch PWNED_B.sh" "x=\`touch PWNED_C\`; echo \"$V_AMR\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "hostile: the files are classified and reported (exit 1)" rc_is 1
  expect "hostile: the substitution file is reported" \
    reports "bin/\$(touch PWNED_A).sh" table-match 1 "$(msg_of amr)"
  expect "hostile: the metacharacter file is reported" \
    reports "bin/a b;touch PWNED_B.sh" table-match 1 "$(msg_of amr)"
  expect "hostile: no file name or content was executed" no_marker_file
}

case_begin "names-within-the-rule-pass" "bin/check-root-names/table-match.js"
c_allowed
case_end

case_begin "names-outside-the-rule-are-reported" "bin/check-root-names/table-match.js"
c_disallowed
case_end

case_begin "carrier-spelling-is-bound-to-its-own-files" "bin/check-root-names/table-match.js"
c_carrier_kinds
case_end

case_begin "first-matching-rule-wins" "bin/check-root-names/table-match.js"
c_first_rule_wins
case_end

case_begin "repo-flag-selects-the-rule-set" "bin/check-root-names.sh"
c_repo_switch
case_end

case_begin "broken-or-missing-table-fails-closed" "bin/check-root-names/table-match.js"
c_broken_table
case_end

. "$(dirname "$0")/feature-2561-root-names/table-match-edges.sh"

case_begin "malformed-table-shapes-exit-2" "bin/check-root-names/table-match.js"
c_broken_shapes
case_end

case_begin "glob-stars-respect-path-segments" "bin/check-root-names/table-match.js"
c_glob_edges
case_end

case_begin "exception-applies-to-its-own-repo" "bin/check-root-names/table-match.js"
c_exception_repo
case_end

case_begin "tree-without-root-names-passes" "bin/check-root-names/table-match.js"
c_empty_tree
case_end

case_begin "rerun-is-stable-and-read-only" "bin/check-root-names.sh"
c_rerun_stable
case_end

case_begin "hostile-names-and-content-are-not-executed" "bin/check-root-names.sh"
c_hostile_text
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
