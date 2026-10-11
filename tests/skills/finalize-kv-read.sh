#!/usr/bin/env bash
# tests/skills/finalize-kv-read.sh
# Tests: skills/issue-close-finalize/scripts/lib/kv-read.sh, skills/issue-close-finalize/scripts/run-finalize-terminal.sh, skills/issue-close-finalize/scripts/run-initial.sh
# Tags: issue-close-finalize, kv-read, eval, injection, security, scope:issue-specific, TL2
# #2561: the finalize scripts read child KEY=VALUE output through lib/kv-read.sh, which
# assigns only the keys the calling script allows and never executes a value. Driven end to
# end through run-finalize-terminal.sh: the state file's owner_repo carries the payload, and
# a stub close-completed.sh records what it received plus an exported sentinel variable.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP_ROOT" || exit 1

SCRIPTS_REL="skills/issue-close-finalize/scripts"

# Working-tree copy (not git ls-files: an uncommitted lib/kv-read.sh must be in it), with
# the close-chain tools replaced by stubs.
CO="$TMP_ROOT/co"
mkdir -p "$CO/skills/issue-close-finalize" "$CO/bin/github-issues"
cp -r "$SCRIPT_CHECKOUT_ROOT/$SCRIPTS_REL" "$CO/$SCRIPTS_REL"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch" "$CO/bin/worker-dispatch"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$CO/hooks"
printf '#!/usr/bin/env bash\nprintf "ARGS=%%s|INJ=%%s\\n" "$*" "${INJ_KEY:-unset}" >> "%s/close.log"\nexit 0\n' "$TMP_ROOT" >"$CO/bin/github-issues/close-completed.sh"
printf '#!/usr/bin/env bash\nprintf "SENT=%%s\\n" "$*" >> "%s/sentinels.log"\nexit 0\n' "$TMP_ROOT" >"$CO/bin/github-issues/post-close-sentinels.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CO/bin/github-issues/wip-state.sh"
printf '"use strict";\n' >"$CO/bin/issue-close-write-outcome.js"
export INJ_KEY=orig

# write_state <owner_repo> [<merge_commit>] — a current-version state file whose owner_repo
# (or merge_commit, when given) is the payload.
write_state() {
  node -e '
const s = require(process.argv[1]);
const st = { schema_version: s.SCHEMA_VERSION, root_issue_number: 7, current_issue_number: 7,
  owner_repo: process.argv[3], phase: "init_done", triage_action: "resume_e",
  g5_loop_iteration: 0, proposal_counters: { accepted: 0, declined: 0, skipped: 0 } };
if (process.argv.length > 4) st.merge_commit = process.argv[4];
require("fs").writeFileSync(process.argv[2], JSON.stringify(st));
' "$CO/bin/worker-dispatch/workers/issue-close-finalize/state.js" "$TMP_ROOT/state.json" "$@"
}

NL=$'\n'
# Rows: label|owner_repo payload (PWN is replaced by a marker path)
ROWS=(
  "semicolon|a/b; touch PWN"
  "no-space-semicolon|a/b;touch PWN"
  "command-substitution|a/b\$(touch PWN)"
  "backtick|a/b\`touch PWN\`"
)

case_begin "kv-read-never-executes-a-value" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
for row in "${ROWS[@]}"; do
  label="${row%%|*}"; marker="$TMP_ROOT/pwned-$label"
  payload="${row#*|}"; payload="${payload//PWN/$marker}"
  rm -f "$TMP_ROOT/close.log"
  write_state "$payload"
  run_with_timeout 30 bash "$CO/$SCRIPTS_REL/run-finalize-terminal.sh" "$TMP_ROOT/state.json" sid-kv "$TMP_ROOT/outcome.json" >"$TMP_ROOT/out" 2>&1
  if [ -e "$marker" ]; then
    fail "kv-read[$label]: value is not executed" "the payload ran (marker created)"
  elif ! grep -qF -- "--repo $payload " "$TMP_ROOT/close.log" 2>/dev/null; then
    fail "kv-read[$label]: the allowed key keeps the literal value" "close.log: $(cat "$TMP_ROOT/close.log" 2>/dev/null) out: $(head -3 "$TMP_ROOT/out")"
  else
    pass "kv-read[$label]: value assigned literally, never executed"
  fi
done
case_end

case_begin "kv-read-ignores-keys-not-allowed" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
rm -f "$TMP_ROOT/close.log"
write_state "a/b${NL}INJ_KEY=injected"
rc=0
run_with_timeout 30 bash "$CO/$SCRIPTS_REL/run-finalize-terminal.sh" "$TMP_ROOT/state.json" sid-kv "$TMP_ROOT/outcome.json" >"$TMP_ROOT/out" 2>&1 || rc=$?
close_log="$(cat "$TMP_ROOT/close.log" 2>/dev/null)"
if grep -q 'INJ=injected' "$TMP_ROOT/close.log" 2>/dev/null; then
  fail "kv-read: a key outside the allowed list is not assigned" "INJ_KEY was overwritten by the child output"
elif [ "$rc" -ne 0 ] || ! grep -q '^STATUS=terminal$' "$TMP_ROOT/out"; then
  fail "kv-read: a key outside the allowed list is not assigned" "finalize did not complete (rc=$rc): $(head -3 "$TMP_ROOT/out")"
elif [ "$close_log" != "ARGS=--repo a/b 7|INJ=orig" ]; then
  fail "kv-read: a key outside the allowed list is not assigned" "close stub did not run with the allowed value: close.log=[$close_log]"
else
  pass "kv-read: a key outside the allowed list is not assigned"
fi
case_end

# A newline in one allowed field must not set ANOTHER allowed key. merge_commit is read after
# triage_action, so "abc<NL>TRIAGE_ACTION=resume_j" would, if honored, flip the action to
# resume_j and skip ICF-H (the close) — the intended action stays resume_e.
case_begin "kv-read-newline-cannot-set-another-allowed-key" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
rm -f "$TMP_ROOT/close.log" "$TMP_ROOT/sentinels.log"
write_state "a/b" "abc${NL}TRIAGE_ACTION=resume_j"
rc=0
run_with_timeout 30 bash "$CO/$SCRIPTS_REL/run-finalize-terminal.sh" "$TMP_ROOT/state.json" sid-kv "$TMP_ROOT/outcome.json" >"$TMP_ROOT/out" 2>&1 || rc=$?
close_log="$(cat "$TMP_ROOT/close.log" 2>/dev/null)"
if [ "$rc" -ne 0 ] || ! grep -q '^STATUS=terminal$' "$TMP_ROOT/out"; then
  fail "kv-read: merge_commit cannot inject TRIAGE_ACTION" "finalize did not complete (rc=$rc): $(head -3 "$TMP_ROOT/out")"
elif [ ! -s "$TMP_ROOT/sentinels.log" ]; then
  fail "kv-read: merge_commit cannot inject TRIAGE_ACTION" "post-close-sentinels stub did not run (case is vacuous)"
elif [ "$close_log" != "ARGS=--repo a/b 7|INJ=orig" ]; then
  fail "kv-read: merge_commit cannot inject TRIAGE_ACTION" "close stub did not run with the intended values (TRIAGE_ACTION=resume_j applied?): close.log=[$close_log]"
else
  pass "kv-read: merge_commit cannot inject TRIAGE_ACTION"
fi
case_end

# run-initial.sh reads 4 children (pre-flight, triage, find-pr-by-marker, g5 prepare). A second
# copy stubs each child to print $KVD/<child>; the gate / parent-body stubs log INJ_KEY, and an
# EVIL tree's gate touches a marker if a child's output re-points SCRIPT_CHECKOUT_ROOT.
CI="$TMP_ROOT/co-init"; KVD="$TMP_ROOT/kv"; EVIL="$TMP_ROOT/evil"
mkdir -p "$CI/skills/issue-close-finalize" "$CI/bin/github-issues" "$KVD" "$EVIL/bin" "$TMP_ROOT/target"
cp -r "$SCRIPT_CHECKOUT_ROOT/$SCRIPTS_REL" "$CI/$SCRIPTS_REL"
for pair in "$SCRIPTS_REL/pre-flight.sh:preflight" "bin/github-issues/issue-close-finalize-triage.sh:triage" \
  "bin/github-issues/find-pr-by-marker.sh:findpr" "$SCRIPTS_REL/step-g5-loop.sh:g5"; do
  printf '#!/usr/bin/env bash\ncat "%s/%s" >> "%s/calls/%s"\ncat "%s/%s"\n' "$KVD" "${pair##*:}" "$TMP_ROOT" "${pair##*:}" "$KVD" "${pair##*:}" >"$CI/${pair%%:*}"
done
printf '#!/usr/bin/env bash\nprintf "gate INJ=%%s\\n" "${INJ_KEY:-unset}" >> "%s/observe.log"\n' "$TMP_ROOT" >"$CI/bin/issue-close-gate.sh"
printf '#!/usr/bin/env bash\nprintf "parent INJ=%%s\\n" "${INJ_KEY:-unset}" >> "%s/observe.log"\n' "$TMP_ROOT" >"$CI/bin/github-issues/parent-body-update.sh"
mkdir -p "$EVIL/bin/github-issues"
for f in bin/issue-close-gate.sh bin/github-issues/find-pr-by-marker.sh; do
  printf '#!/usr/bin/env bash\ntouch "%s/pwned-evil-root"\n' "$TMP_ROOT" >"$EVIL/$f"
done

# Rows: label|child whose output is replaced|output (PWN = marker path, EVIL = evil tree, \n = newline)
INIT_ROWS=(
  "baseline|-|-"
  "preflight-semicolon|preflight|OWNER_REPO=a/b; touch PWN"
  "preflight-subst|preflight|OWNER_REPO=a/b\$(touch PWN)"
  "preflight-backtick|preflight|OWNER_REPO=a/b\`touch PWN\`"
  "triage-semicolon|triage|STATE=open\nSENTINEL=none\nACTION=resume_e;touch PWN\nNEXT_STEPS=J,B,G"
  "findpr-subst|findpr|PR_NUMBER=5\$(touch PWN)\nMERGE_COMMIT=abc"
  "g5-backtick|g5|PROPOSAL_STATUS=skipped\`touch PWN\`"
  "preflight-newline-unapproved|preflight|OWNER_REPO=a/b\nINJ_KEY=injected"
  "triage-newline-root|triage|STATE=open\nSENTINEL=none\nACTION=resume_e\nNEXT_STEPS=J,B,G\nSCRIPT_CHECKOUT_ROOT=EVIL"
  "findpr-newline-root|findpr|PR_NUMBER=5\nMERGE_COMMIT=abc\nSCRIPT_CHECKOUT_ROOT=EVIL"
  "g5-newline-unapproved|g5|PROPOSAL_STATUS=skipped\nISSUE_NUMBER=999"
)

case_begin "run-initial-child-output-never-executes-or-injects" "skills/issue-close-finalize/scripts/run-initial.sh"
for row in "${INIT_ROWS[@]}"; do
  label="${row%%|*}"; rest="${row#*|}"; child="${rest%%|*}"; body="${rest#*|}"
  marker="$TMP_ROOT/pwned-$label"
  rm -rf "$TMP_ROOT/observe.log" "$TMP_ROOT/pwned-evil-root" "$TMP_ROOT/calls"
  mkdir -p "$TMP_ROOT/calls"
  printf 'OWNER_REPO=a/b\n' >"$KVD/preflight"
  printf 'STATE=open\nSENTINEL=none\nACTION=resume_e\nNEXT_STEPS=J,B,G\n' >"$KVD/triage"
  printf 'PR_NUMBER=5\nMERGE_COMMIT=abc\n' >"$KVD/findpr"
  printf 'PROPOSAL_STATUS=skipped\n' >"$KVD/g5"
  if [ "$child" != "-" ]; then
    body="${body//PWN/$marker}"; body="${body//EVIL/$EVIL}"
    printf '%b\n' "$body" >"$KVD/$child"
  fi
  rc=0
  INJ_KEY=orig FINALIZE_SCRIPTS_DIR="$CI/$SCRIPTS_REL" run_with_timeout 30 bash "$CI/$SCRIPTS_REL/run-initial.sh" \
    --target-main-root "$TMP_ROOT/target" 7 7 >"$TMP_ROOT/init.out" 2>"$TMP_ROOT/init.err" || rc=$?
  why=""
  [ -e "$marker" ] && why="the payload ran (marker created)"
  [ -e "$TMP_ROOT/pwned-evil-root" ] && why="SCRIPT_CHECKOUT_ROOT was re-pointed by child output"
  grep -q 'INJ=injected' "$TMP_ROOT/observe.log" 2>/dev/null && why="INJ_KEY (not an allowed key) was assigned"
  grep -q '#999' "$TMP_ROOT/init.out" && why="ISSUE_NUMBER (not an allowed key) was assigned"
  # No breach seen: every child, the injected one included, must have emitted its output once,
  # or a skipped child step would pass vacuously.
  if [ -z "$why" ]; then
    for c in preflight triage findpr g5; do
      if ! cmp -s "$KVD/$c" "$TMP_ROOT/calls/$c"; then why="child $c was not invoked exactly once with its output (case is vacuous)"; break; fi
    done
  fi
  if [ -z "$why" ]; then
    if [ "$rc" -ne 0 ] || ! grep -q '^STATUS=init_done$' "$TMP_ROOT/init.out"; then
      why="run did not complete (rc=$rc): $(head -3 "$TMP_ROOT/init.out") $(head -3 "$TMP_ROOT/init.err")"
    elif ! grep -q 'gate INJ=orig' "$TMP_ROOT/observe.log" 2>/dev/null; then
      why="the gate observer did not run (case is vacuous)"
    elif [ "$label" = baseline ] && ! grep -q '^PR_NUMBER=5$' "$TMP_ROOT/init.out"; then
      why="allowed keys were not assigned: $(tr '\n' ' ' <"$TMP_ROOT/init.out")"
    fi
  fi
  if [ -n "$why" ]; then fail "run-initial[$label]: child output is read as data only" "$why"
  else pass "run-initial[$label]: child output is read as data only"; fi
done
case_end

case_begin "finalize-scripts-read-through-kv-read" "skills/issue-close-finalize/scripts/run-initial.sh"
for s in run-finalize-terminal.sh run-initial.sh; do
  f="$SCRIPT_CHECKOUT_ROOT/$SCRIPTS_REL/$s"
  if grep -nE '^[[:space:]]*eval[[:space:]]' "$f" >"$TMP_ROOT/evals"; then
    fail "$s: no eval of child output" "$(cat "$TMP_ROOT/evals")"
  elif ! grep -q 'kv-read.sh' "$f"; then
    fail "$s: reads child output through lib/kv-read.sh" "no reference to kv-read.sh"
  else
    pass "$s: reads child output through lib/kv-read.sh, no eval"
  fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
