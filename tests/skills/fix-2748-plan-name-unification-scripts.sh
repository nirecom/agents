#!/usr/bin/env bash
# tests/skills/fix-2748-plan-name-unification-scripts.sh
# Tests: skills/clarify-intent/scripts/run-completion.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh
# Tags: TL2, regression-2748, scope:issue-specific, plan-artifact, pwsh-not-required
# #2748 U8/U9/U10: the plan writers resolve their plan paths through bin/plan-artifact-path and fail
# closed when it cannot answer. Stub checkout, only bin/plan-artifact-path real; invalid sid + session-downstream.
# The JS side of #2748 (U1-U7) lives in tests/hooks/fix-2748-plan-name-unification.js.
# TL3 gap (what this test does NOT catch):
# - real collaborators (check-plan-approval, concern-ledger, codex) misreading the resolved plan paths.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
mkdir -p "$TMP_ROOT/transcripts" "$TMP_ROOT/neutral"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"
NEUTRAL="$TMP_ROOT/neutral"
REAL_PAP="$(np "$SCRIPT_CHECKOUT_ROOT/bin/plan-artifact-path")"
# A session-downstream (DOWN_SID) adopted from FIRST_SID: its state names FIRST_SID as first_session_id,
# so every plan path resolves to FIRST_SID's name, never to DOWN_SID's own.
readonly FIRST_SID="s2748-first" DOWN_SID="s2748-down"
printf '{"version":5,"events":[],"first_session_id":"%s","previous_session_ids":["%s"]}\n' "$FIRST_SID" "$FIRST_SID" \
  >"$WORKFLOW_STATE_DIR/$DOWN_SID.json"

# stub_tree <root> <script-rel> — the real script under test plus the real bin/plan-artifact-path
# behind a shim; the caller writes its own stub tools into <root> afterwards.
stub_tree() {
  local root="$1" rel="$2"
  mkdir -p "$root/$(dirname "$rel")" "$root/bin"
  cp "$SCRIPT_CHECKOUT_ROOT/$rel" "$root/$rel"
  printf '#!/usr/bin/env node\nrequire(%s);\n' "\"$REAL_PAP\"" >"$root/bin/plan-artifact-path"
  chmod +x "$root/$rel" "$root/bin/plan-artifact-path"
}

# run_script <root> <script-rel> <stdout> <stderr> [args...] — runs from a neutral cwd and HOME; prints the exit code.
run_script() {
  local root="$1" rel="$2" out="$3" err="$4" rc=0
  shift 4
  (cd "$NEUTRAL" && HOME="$NEUTRAL" USERPROFILE="$NEUTRAL" run_with_timeout 90 bash "$root/$rel" "$@") \
    >"$out" 2>"$err" || rc=$?
  printf '%s' "$rc"
}

# --- U8 fixture: run-completion.sh with every collaborator stubbed except plan-artifact-path ---
U8_SCRIPT="skills/clarify-intent/scripts/run-completion.sh"
U8_ROOT="$TMP_ROOT/tree-u8"
U8_PLANS="$TMP_ROOT/plans-u8"
U8_MARKER="$(np "$TMP_ROOT/u8-parse-called.txt")"
mkdir -p "$U8_PLANS" "$U8_ROOT/bin/workflow" "$U8_ROOT/bin/github-issues" "$U8_ROOT/hooks/lib"
printf '# intent\n\nCloses #1\n' >"$U8_PLANS/bad.sid-intent.md"
stub_tree "$U8_ROOT" "$U8_SCRIPT"
cat >"$U8_ROOT/bin/workflow/check-plan-approval" <<'STUB'
#!/usr/bin/env node
process.stdout.write('APPROVAL=approved\n');
STUB
cat >"$U8_ROOT/bin/is-github-dotcom-remote" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$U8_ROOT/hooks/lib/parse-closes-issues.js" <<STUB
"use strict";
const fs = require("fs");
module.exports = { parseClosesIssues(p) { fs.writeFileSync("$U8_MARKER", String(p)); return []; } };
STUB
cat >"$U8_ROOT/bin/github-issues/clarify-commit-scope.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$U8_ROOT/bin/github-issues/clarify-guard-loop.sh" <<'STUB'
#!/usr/bin/env bash
echo PROCEED
exit 0
STUB
chmod +x "$U8_ROOT/bin/workflow/check-plan-approval" "$U8_ROOT/bin/is-github-dotcom-remote" \
  "$U8_ROOT/bin/github-issues/clarify-commit-scope.sh" "$U8_ROOT/bin/github-issues/clarify-guard-loop.sh"
U8_RC="$(run_script "$U8_ROOT" "$U8_SCRIPT" "$TMP_ROOT/u8.out" "$TMP_ROOT/u8.err" \
  --session-id bad.sid --plans-dir "$(np "$U8_PLANS")")"
U8_ERR="$(cat "$TMP_ROOT/u8.err")"

case_begin "run-completion-fails-closed-without-an-intent-path" "skills/clarify-intent/scripts/run-completion.sh"
if [[ "$U8_RC" != "0" ]]; then
  pass "U8: an invalid session id makes run-completion.sh exit non-0"
else
  fail "U8: an invalid session id makes run-completion.sh exit non-0" "exit=$U8_RC stderr=$U8_ERR"
fi
if [[ "$U8_ERR" == *"cannot resolve the intent path"* ]]; then
  pass "U8: stderr says 'cannot resolve the intent path'"
else
  fail "U8: stderr says 'cannot resolve the intent path'" "stderr=$U8_ERR"
fi
if [[ ! -e "$U8_MARKER" ]]; then
  pass "U8: \$PLANS_DIR/<SESSION_ID>-intent.md is never handed to the closes parser"
else
  fail "U8: \$PLANS_DIR/<SESSION_ID>-intent.md is never handed to the closes parser" "parser read $(cat "$U8_MARKER")"
fi
case_end

# U8 happy path: the session-downstream's own-sid intent is a decoy; the parser must read FIRST_SID's.
printf '# intent\n\nCloses #1\n' >"$U8_PLANS/$FIRST_SID-intent.md"
printf '# decoy\n' >"$U8_PLANS/$DOWN_SID-intent.md"
U8_EXPECTED="$(node "$REAL_PAP" --stage intent --session "$DOWN_SID" --plans-dir "$(np "$U8_PLANS")")"
U8_OK_RC="$(run_script "$U8_ROOT" "$U8_SCRIPT" "$TMP_ROOT/u8ok.out" "$TMP_ROOT/u8ok.err" \
  --session-id "$DOWN_SID" --plans-dir "$(np "$U8_PLANS")")"
U8_OK_READ="$(cat "$U8_MARKER" 2>/dev/null || true)"

case_begin "run-completion-hands-first-session-intent-to-parser" "skills/clarify-intent/scripts/run-completion.sh"
if [[ "$U8_OK_RC" == "0" && "$(tail -n1 "$TMP_ROOT/u8ok.out")" == "PROCEED" ]]; then
  pass "U8: a session-downstream sid makes run-completion.sh exit 0 with PROCEED"
else
  fail "U8: a session-downstream sid makes run-completion.sh exit 0 with PROCEED" \
    "exit=$U8_OK_RC stdout=$(cat "$TMP_ROOT/u8ok.out") stderr=$(cat "$TMP_ROOT/u8ok.err")"
fi
if [[ -n "$U8_OK_READ" && "$U8_OK_READ" == "$U8_EXPECTED" && "${U8_OK_READ##*[/\\]}" == "$FIRST_SID-intent.md" ]]; then
  pass "U8: the closes parser reads exactly the first_session_id intent path from bin/plan-artifact-path"
else
  fail "U8: the closes parser reads exactly the first_session_id intent path from bin/plan-artifact-path" \
    "parser read '$U8_OK_READ', expected '$U8_EXPECTED'"
fi
case_end

# --- U9 fixture: the detail review loop with its control, ledger and loop tools stubbed ---
U9_SCRIPT="skills/make-detail-plan/scripts/run-codex-review-loop.sh"
U9_ROOT="$TMP_ROOT/tree-u9"
U9_PLANS="$TMP_ROOT/plans-u9"
U9_CONTROL="$(np "$TMP_ROOT/control-u9")"
U9_MARKER="$(np "$TMP_ROOT/u9-loop-called.txt")"
mkdir -p "$U9_PLANS" "$TMP_ROOT/control-u9"
printf '# intent\n' >"$U9_PLANS/bad.sid-intent.md"

# review_loop_tree <root> <script-rel> <control-dir> <marker> — stub_tree plus stubbed control,
# ledger and loop tools; the loop stub records its arguments one per line into <marker>.
review_loop_tree() {
  local root="$1" rel="$2" control="$3" marker="$4"
  mkdir -p "$root/bin/lib/codex-review-loop"
  stub_tree "$root" "$rel"
  cat >"$root/bin/lib/codex-review-loop/review-wrapper-control.sh" <<STUB
rwc_resolve() { CONTROL_DIR="$control"; TERMINAL_FILE="$control/terminal"; return 0; }
rwc_check_terminal() { return 0; }
sp_control_dir() { printf '%s\\n' "$control/risk.txt"; }
STUB
  cat >"$root/bin/resolve-accepted-tradeoffs-file" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "$control/tradeoffs.md"
exit 0
STUB
  cat >"$root/bin/concern-ledger" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
  cat >"$root/bin/run-codex-review-loop" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$@" >"$marker"
exit 0
STUB
  chmod +x "$root/bin/lib/codex-review-loop/review-wrapper-control.sh" "$root/bin/resolve-accepted-tradeoffs-file" \
    "$root/bin/concern-ledger" "$root/bin/run-codex-review-loop"
}
review_loop_tree "$U9_ROOT" "$U9_SCRIPT" "$U9_CONTROL" "$U9_MARKER"
U9_RC="$(SESSION_ID=bad.sid PLANS_DIR="$(np "$U9_PLANS")" EXTENSIONS_USED=0 \
  run_script "$U9_ROOT" "$U9_SCRIPT" "$TMP_ROOT/u9.out" "$TMP_ROOT/u9.err")"
U9_ERR="$(cat "$TMP_ROOT/u9.err")"

case_begin "detail-review-loop-halts-without-plan-paths" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
if [[ "$U9_RC" == "4" ]]; then
  pass "U9: an invalid session id makes the detail review loop exit 4 (HALT)"
else
  fail "U9: an invalid session id makes the detail review loop exit 4 (HALT)" "exit=$U9_RC stderr=$U9_ERR"
fi
if [[ ! -e "$U9_MARKER" ]]; then
  pass "U9: the review loop itself is never started"
else
  fail "U9: the review loop itself is never started" "run-codex-review-loop ran with $(cat "$U9_MARKER")"
fi
case_end

# U9 happy path: the session-downstream's review loop gets FIRST_SID's plans; PLANS_DIR keeps its spelling.
U9_PLANS_ARG="$(np "$U9_PLANS")"
U9_OK_RC="$(SESSION_ID="$DOWN_SID" PLANS_DIR="$U9_PLANS_ARG" EXTENSIONS_USED=0 \
  run_script "$U9_ROOT" "$U9_SCRIPT" "$TMP_ROOT/u9ok.out" "$TMP_ROOT/u9ok.err")"
# arg_after <flag> [marker] — the recorded argument that follows <flag> (one argument per marker line).
arg_after() {
  awk -v f="$1" 'hit { print; exit } $0 == f { hit = 1 }' "${2:-$U9_MARKER}" 2>/dev/null || true
}

case_begin "detail-review-loop-gets-first-session-plan-paths" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
if [[ "$U9_OK_RC" == "0" && -e "$U9_MARKER" ]]; then
  pass "U9: a session-downstream sid starts the review loop and exits 0"
else
  fail "U9: a session-downstream sid starts the review loop and exits 0" "exit=$U9_OK_RC stderr=$(cat "$TMP_ROOT/u9ok.err")"
fi
for pair in "--class-members:intent" "--draft-file:detail"; do
  flag="${pair%%:*}" stage="${pair##*:}"
  got="$(arg_after "$flag")"
  if [[ "$got" == "$U9_PLANS_ARG/$FIRST_SID-$stage.md" ]]; then
    pass "U9: $flag is the first_session_id $stage path"
  else
    fail "U9: $flag is the first_session_id $stage path" "got '$got', expected '$U9_PLANS_ARG/$FIRST_SID-$stage.md'"
  fi
done
case_end

# --- U10: the outline review loop from the same session-downstream; own-sid plans are decoys ---
U10_SCRIPT="skills/make-outline-plan/scripts/run-codex-review-loop.sh"
U10_ROOT="$TMP_ROOT/tree-u10"
U10_PLANS="$TMP_ROOT/plans-u10"
U10_CONTROL="$(np "$TMP_ROOT/control-u10")"
U10_MARKER="$(np "$TMP_ROOT/u10-loop-called.txt")"
mkdir -p "$U10_PLANS" "$TMP_ROOT/control-u10"
for stage in intent outline; do
  printf '# %s\n' "$stage" >"$U10_PLANS/$FIRST_SID-$stage.md"
  printf '# decoy\n' >"$U10_PLANS/$DOWN_SID-$stage.md"
done
review_loop_tree "$U10_ROOT" "$U10_SCRIPT" "$U10_CONTROL" "$U10_MARKER"
U10_PLANS_ARG="$(np "$U10_PLANS")"
U10_RC="$(SESSION_ID="$DOWN_SID" PLANS_DIR="$U10_PLANS_ARG" EXTENSIONS_USED=0 \
  run_script "$U10_ROOT" "$U10_SCRIPT" "$TMP_ROOT/u10.out" "$TMP_ROOT/u10.err")"

case_begin "outline-review-loop-gets-first-session-plan-paths" "skills/make-outline-plan/scripts/run-codex-review-loop.sh"
if [[ "$U10_RC" == "0" && -e "$U10_MARKER" ]]; then
  pass "U10: a session-downstream sid starts the outline review loop and exits 0"
else
  fail "U10: a session-downstream sid starts the outline review loop and exits 0" \
    "exit=$U10_RC stderr=$(cat "$TMP_ROOT/u10.err")"
fi
for pair in "--class-members:intent" "--draft-file:outline"; do
  flag="${pair%%:*}" stage="${pair##*:}"
  got="$(arg_after "$flag" "$U10_MARKER")"
  if [[ "$got" == "$U10_PLANS_ARG/$FIRST_SID-$stage.md" ]]; then
    pass "U10: $flag is the first_session_id $stage path"
  else
    fail "U10: $flag is the first_session_id $stage path" "got '$got', expected '$U10_PLANS_ARG/$FIRST_SID-$stage.md'"
  fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
