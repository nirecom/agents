#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/structural.js
# Tags: root-names, structural, carrier, gate, static-check, bin, scope:issue-specific, TL2
# #2561: the structural rules of the root-name gate — what a name may be joined
# to, where it may cross a process boundary, and who may write a carrier.
# TL3 gap (what this test does NOT catch):
# - the real tree; the scan test runs every check over the checkout.
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

# Fixture text is assembled from fragments so that no line of this file has a
# shape the gate rejects.
ALL_NAMES="\"$N_SCR\",\"$N_AMR\",\"$N_TMR\",\"$N_TCR\""
REAL_ROOT_CALL="root_decoy_use_""real_main_root"
MODIFIED_PARAM="fakeS${CAMEL_SCR#s}"
EXC_SUBPATH="{\"file\":\"bin/a-excepted.sh\",\"allow\":[\"$N_SCR\",\"$N_AMR\"],\"forms\":[\"agents-root-subpath\"],\"reason\":\"fixture\"}"
EXC_REAL="{\"file\":\"tests/e-allowed.sh\",\"allow\":[$ALL_NAMES],\"forms\":[\"leave-decoy\"],\"reason\":\"fixture\"}"

# The fixture rows (structural_rows) and the message of each verdict key (msg_of).
. "$(dirname "$0")/feature-2561-root-names/structural-rows.sh"

# next_row — read one fixture row into name / rule / want / path / line and set
# class to reported, clean or clean-alone. Fails at the end of the table.
next_row() {
  while IFS='|' read -r name rule want path line; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    rule="${rule//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    path="${path//[[:space:]]/}"
    line="${line# }"
    class=reported
    [[ "$want" == clean* ]] && class="$want"
    return 0
  done
  return 1
}

# has_row <rule> <class> — the table holds at least one such row.
has_row() {
  local name rule want path line class
  while next_row; do
    [[ "$rule" == "$1" && "$class" == "$2" ]] && return 0
  done < <(structural_rows)
  return 1
}

# seed_rows <rule> <class>... — write the fixture file of each such row into $REPO.
seed_rows() {
  local pick="$1" name rule want path line class
  shift
  while next_row; do
    [[ "$rule" == "$pick" && " $* " == *" $class "* ]] || continue
    fx "$REPO/$path" "$line"
  done < <(structural_rows)
}

# expect_table <rule> <label> <class>... — one assertion per such row: a reported row
# names its line and its message, a clean row has no line of the check at all.
expect_table() {
  local pick="$1" label="$2" name rule want path line class at
  shift 2
  while next_row <&3; do
    [[ "$rule" == "$pick" && " $* " == *" $class "* ]] || continue
    if [[ "$class" == reported ]]; then
      at=1
      [[ "$want" == blind ]] && at=0
      expect "$label rejected: $name ($path, $want)" reports "$path" structural "$at" "$(msg_of "$want")"
    else
      expect "$label accepted: $name ($path)" clean_for "$path" structural
    fi
  done 3< <(structural_rows)
}

# run_rule <kit-name> <rule> <class>... — one committed fixture tree: the carrier
# sources every tree needs plus the rule's rows of the given classes; sets KIT / REPO
# and runs the structural check.
run_rule() {
  local kit="$1" pick="$2"
  shift 2
  make_kit "$kit"
  write_table "$KIT" "$EXC_SUBPATH" "$EXC_REAL"
  new_repo "$kit"
  seed_rows carrier clean
  seed_rows "$pick" "$@"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
}

# c_rule <rule> <exit-1 message> <exit-0 message> — both verdicts of one rule.
c_rule() {
  local pick="$1"
  expect "$pick: the table holds a rejected row" has_row "$pick" reported
  expect "$pick: the table holds an accepted row" has_row "$pick" clean
  run_rule "$pick-bad" "$pick" reported clean
  expect "$pick: $2" rc_is 1
  expect_table "$pick" "$pick" reported clean
  run_rule "$pick-good" "$pick" clean clean-alone
  expect "$pick: $3" rc_is 0
  expect_table "$pick" "$pick alone" clean clean-alone
}

c_payload_key_declared() {
  make_kit key-missing
  write_table "$KIT"
  new_repo key-missing
  seed_rows carrier clean
  fx "$REPO/hooks/key-src.js" 'const KEY = "another_key";'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "payload key: a source without the declaration is reported" \
    reports "hooks/key-src.js" structural 0 'does not declare it'
  fx "$REPO/hooks/key-src.js" "const KEY = \"$C_KEY\";"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "payload key: the declaration in the source clears it (exit 0)" rc_is 0
  git -C "$REPO" rm -q hooks/key-src.js
  fx "$REPO/hooks/key-blind.js" "use(payload.$C_KEY);"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "payload key: a tree without the source says nothing about the source" never_says 'does not declare it'
  expect "payload key: a reader that never compares is still reported there" \
    reports "hooks/key-blind.js" structural 0 "$(msg_of blind)"
  expect "payload key: the comparing reader stays accepted there" clean_for "hooks/key-user.js" structural
}

c_exception_is_per_file() {
  make_kit per-file
  write_table "$KIT" "$EXC_SUBPATH" "$EXC_REAL"
  new_repo per-file
  fx "$REPO/bin/a-excepted.sh" "bash \"$V_AMR/bin/tool\"" "export $N_SCR"
  fx "$REPO/tests/e-allowed.sh" "$REAL_ROOT_CALL" "node \"$V_AMR/hooks/x.js\""
  fx "$REPO/bin/sub/a-excepted.sh" "bash \"$V_AMR/bin/tool\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "exception: exits 1" rc_is 1
  expect "exception: the freed form of the named file is silent" silent_on "bin/a-excepted.sh" structural 1
  expect "exception: its other rule still reports" \
    reports "bin/a-excepted.sh" structural 2 "$(msg_of exported)"
  expect "exception: the other named file is free to leave the decoy" silent_on "tests/e-allowed.sh" structural 1
  expect "exception: and keeps its other rules" reports "tests/e-allowed.sh" structural 2 "$(msg_of sub)"
  expect "exception: a same-named file elsewhere is not covered" \
    reports "bin/sub/a-excepted.sh" structural 1 "$(msg_of sub)"
}

c_rerun_stable() {
  make_kit rerun
  write_table "$KIT" "$EXC_SUBPATH" "$EXC_REAL"
  new_repo rerun
  seed_rows subpath reported clean
  seed_rows handover reported
  seed_rows parameter clean
  commit_all "$REPO"
  expect_rerun_stable "rerun" 1 "$REPO" "$KIT" --root "$REPO" --only structural
}

c_hostile_text() {
  make_kit hostile
  write_table "$KIT"
  new_repo hostile
  fx "$REPO/bin/\$(touch PWNED_A).sh" "bash \"$V_AMR/bin/tool\""
  fx "$REPO/bin/x;touch PWNED_B;.sh" "export $N_SCR; \`touch PWNED_C\`; \$(touch PWNED_D)"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only structural
  expect "hostile: the files are read and reported (exit 1)" rc_is 1
  expect "hostile: the substitution file is reported" \
    reports "bin/\$(touch PWNED_A).sh" structural 1 "$(msg_of sub)"
  expect "hostile: the metacharacter file is reported" \
    reports "bin/x;touch PWNED_B;.sh" structural 1 "$(msg_of exported)"
  expect "hostile: no file name or content was executed" no_marker_file
}

case_begin "agents-root-code-subpath-is-rejected" "bin/check-root-names/structural.js"
c_rule subpath "the rejected shapes exit 1" "the accepted shapes alone exit 0"
case_end

case_begin "checkout-root-never-crosses-a-process" "bin/check-root-names/structural.js"
c_rule handover "the rejected shapes exit 1" "the accepted shapes alone exit 0"
case_end

case_begin "checkout-root-is-not-a-parameter" "bin/check-root-names/structural.js"
c_rule parameter "the rejected shapes exit 1" "the accepted shapes alone exit 0"
case_end

case_begin "only-the-source-writes-a-carrier" "bin/check-root-names/structural.js"
c_rule carrier "writes outside the source exit 1" "the source writes and the others read (exit 0)"
case_end

case_begin "payload-key-is-declared-in-its-source" "bin/check-root-names/structural.js"
c_payload_key_declared
case_end

case_begin "leaving-the-decoy-needs-an-exception" "bin/check-root-names/structural.js"
c_rule real-root "the rejected shapes exit 1" "the accepted shapes alone exit 0"
case_end

case_begin "exception-frees-one-form-of-one-file" "bin/check-root-names/structural.js"
c_exception_is_per_file
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
