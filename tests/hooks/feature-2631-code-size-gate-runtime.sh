#!/usr/bin/env bash
# tests/hooks/feature-2631-code-size-gate-runtime.sh
# Tests: hooks/workflow-gate/code-size-gate.js
# Tags: scope:issue-specific, size-limits, workflow-gate, gate2, code-size, hook, block, shrink, ssot, layer:TL2, session-marker
# #2631: Gate 2 of hooks/workflow-gate.js is run for real (no stub) against temp repos: the
# verdict follows the SSOT hooks/lib/size-limits.js of the launched checkout through
# bin/review-code-size --staged -> bin/size-check, whatever the repo under test is named.
# TL3 gap: the PreToolUse registration of the hook for a real Bash tool call is not exercised;
# it is checked at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh, hook-registration).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
harness_assert_isolated
unset CODE_FILE_EXTENSIONS 2>/dev/null || true
ROOT_NODE="$(np "$ROOT")"

# shellcheck source=tests/lib/session-repo-fixture.sh
. "$ROOT/tests/lib/session-repo-fixture.sh"
CHECKOUT="$TMP_ROOT/checkout"
session_repo_fixture_create "$CHECKOUT"
# A second copy whose SSOT is rewritten, so the first copy keeps the repo numbers.
MUTATED="$TMP_ROOT/checkout-mutated"
session_repo_fixture_create "$MUTATED"
# The settings dir: no .env, so CODE_FILE_EXTENSIONS takes its default.
CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG"
CFG="$(np "$CFG")"

make_lines() {
  local n="$1" tag="${2:-line}" i
  for ((i = 1; i <= n; i++)); do echo "$tag $i"; done
}

# new_repo <name> — a committed temp repo; prints its node path.
new_repo() {
  local d="$TMP_ROOT/repos/$1"
  mkdir -p "$d"
  harness_git_init "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name T
  git -C "$d" config core.autocrlf false
  echo init > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m init
  np "$d"
}

# put_file <repo> <rel> <n> [tag] [commit] — writes and stages <n> lines; commits when asked.
put_file() {
  local repo="$1" rel="$2" n="$3" tag="${4:-line}" commit="${5:-}"
  mkdir -p "$(dirname "$repo/$rel")"
  make_lines "$n" "$tag" > "$repo/$rel"
  git -C "$repo" add -- "$rel"
  [[ -z "$commit" ]] || git -C "$repo" commit -q -m "add $rel"
}

# write_state <sid> <cwd> — every step complete and the gated steps approved (#2277).
write_state() {
  local file="$WORKFLOW_STATE_DIR/$1.json"
  STATE_SID="$1" STATE_CWD="$2" STATE_FILE="$file" node -e '
const fs = require("fs");
const { VALID_STEPS } = require(process.argv[1] + "/hooks/workflow-state.js");
const now = new Date().toISOString();
const steps = {};
for (const s of VALID_STEPS) steps[s] = { status: "complete", updated_at: now };
const state = { version: 1, session_id: process.env.STATE_SID, created_at: now, steps, cwd: process.env.STATE_CWD };
fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2));
' "$ROOT_NODE"
  node "$ROOT_NODE/tests/lib/plan-approval-fixture.js" inject "$file" clarify_intent outline detail >/dev/null
}

payload() {
  node -e 'process.stdout.write(JSON.stringify({session_id: process.argv[1], tool_name: "Bash",
    tool_input: {command: "git -C " + process.argv[2] + " commit -m test"}}))' "$1" "$2"
}

HOOK_OUT=""
HOOK_RC=0
# run_gate_once <sid> <repo> <checkout> <owner> — launch the checkout's hook for a commit in <repo>.
run_gate_once() {
  local sid="$1" repo="$2" checkout="$3" owner="$4"
  HOOK_RC=0
  session_repo_fixture_attach "$checkout" "$owner"
  HOOK_OUT="$(payload "$sid" "$repo" | run_with_timeout 60 env -u CODE_FILE_EXTENSIONS \
    "AGENTS_MAIN_ROOT=$CFG" node "$(session_repo_fixture_path "$checkout" hooks/workflow-gate.js)" 2>&1)" || HOOK_RC=$?
}

# run_gate <sid> <repo> [checkout] [owner] — re-run (bounded) an attempt that hit the gate's own
# 3 s fail-open timeout: under host load it would turn a block case into an approve.
run_gate() {
  local attempt
  for attempt in 1 2 3; do
    run_gate_once "$1" "$2" "${3:-$CHECKOUT}" "${4:-$2}"
    [[ "$HOOK_OUT" == *"timed out"* || "$HOOK_OUT" == *ETIMEDOUT* ]] || return 0
    echo "    note: incidental review-code-size timeout, attempt $attempt" >&2
  done
}

# expect_decision <label> <approve|block> [needle]
expect_decision() {
  local label="$1" want="$2" needle="${3:-}"
  if [[ "$HOOK_RC" -ne 0 ]]; then fail "$label" "hook rc=$HOOK_RC: $HOOK_OUT"; return 0; fi
  if [[ "$HOOK_OUT" != *"\"decision\":\"$want\""* ]]; then fail "$label" "expected $want: $HOOK_OUT"; return 0; fi
  if [[ -n "$needle" && "$HOOK_OUT" != *"$needle"* ]]; then fail "$label" "reason lacks '$needle': $HOOK_OUT"; return 0; fi
  pass "$label"
}

case_begin "new-file-over-hard-blocks-naming-the-file" "hooks/workflow-gate/code-size-gate.js"
repo="$(new_repo a1)"
write_state sid-a1 "$repo"
put_file "$repo" src/big.js 501
run_gate sid-a1 "$repo"
expect_decision "a new 501-line src/big.js blocks" block src/big.js
expect_decision "the block reason carries the HARD marker" block HARD
repo="$(new_repo a2)"
write_state sid-a2 "$repo"
put_file "$repo" src/edge.js 500
run_gate sid-a2 "$repo"
expect_decision "a new file at exactly HARD (500) approves" approve
case_end

case_begin "within-limits-approves" "hooks/workflow-gate/code-size-gate.js"
repo="$(new_repo b1)"
write_state sid-b1 "$repo"
put_file "$repo" src/small.js 10
run_gate sid-b1 "$repo"
expect_decision "a new 10-line src/small.js approves" approve
repo="$(new_repo b2)"
write_state sid-b2 "$repo"
put_file "$repo" src/warn.js 350
run_gate sid-b2 "$repo"
expect_decision "a new 350-line file (WARN range, under HARD) approves" approve
case_end

case_begin "over-hard-head-file-shrink-approves" "hooks/workflow-gate/code-size-gate.js"
repo="$(new_repo c1)"
write_state sid-c1 "$repo"
put_file "$repo" src/old.js 600 line commit
put_file "$repo" src/old.js 550
run_gate sid-c1 "$repo"
expect_decision "src/old.js 600 -> 550 (shrink, still over HARD) approves" approve
case_end

case_begin "over-hard-head-file-grow-or-same-blocks" "hooks/workflow-gate/code-size-gate.js"
repo="$(new_repo d1)"
write_state sid-d1 "$repo"
put_file "$repo" src/old.js 600 line commit
put_file "$repo" src/old.js 610
run_gate sid-d1 "$repo"
expect_decision "src/old.js 600 -> 610 (grow) blocks" block src/old.js
put_file "$repo" src/old.js 600 v2
run_gate sid-d1 "$repo"
expect_decision "src/old.js 600 -> 600 (edited, same count) blocks" block src/old.js
case_end

# The hook is launched from a checkout of an unrelated repo; the commit goes to a repo whose
# name says nothing about agents, which the session's cwd puts in the WF target repo set.
case_begin "arbitrary-repo-name-judged-by-the-ssot" "hooks/workflow-gate/code-size-gate.js"
foreign="$(new_repo "owner-$RANDOM")"
repo="$(new_repo "zq-arbitrary-$RANDOM")"
write_state sid-e1 "$repo"
put_file "$repo" lib/huge.js 501
run_gate sid-e1 "$repo" "$CHECKOUT" "$foreign"
expect_decision "arbitrary repo: a new 501-line lib/huge.js blocks" block lib/huge.js
repo="$(new_repo "zq-control-$RANDOM")"
write_state sid-e2 "$repo"
put_file "$repo" lib/tiny.js 20
run_gate sid-e2 "$repo" "$CHECKOUT" "$foreign"
expect_decision "control: the same route with a 20-line file approves" approve
case_end

case_begin "ssot-limit-change-moves-the-gate-verdict" "hooks/workflow-gate/code-size-gate.js"
if node "$ROOT_NODE/tests/hooks/feature-2631-size-limits/mutate-limits.js" "$(np "$MUTATED")" code 50 100; then
  pass "premise: the mutated checkout's SSOT says code 50/100"
else
  fail "premise: the mutated checkout's SSOT says code 50/100"
fi
repo="$(new_repo f1)"
write_state sid-f1 "$repo"
put_file "$repo" src/mid.js 150
run_gate sid-f1 "$repo" "$MUTATED"
expect_decision "lowered HARD 100: a new 150-line src/mid.js blocks" block src/mid.js
run_gate sid-f1 "$repo" "$CHECKOUT"
expect_decision "control: the unmodified SSOT approves the same staged file" approve
case_end

case_begin "workflow-off-marker-approves" "hooks/workflow-gate/code-size-gate.js"
repo="$(new_repo g1)"
write_state sid-g1 "$repo"
printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$WORKFLOW_STATE_DIR/sid-g1.workflow-off"
put_file "$repo" src/big.js 501
run_gate sid-g1 "$repo"
expect_decision "WORKFLOW_OFF marker: a new 501-line file approves" approve
repo="$(new_repo g2)"
write_state sid-g2 "$repo"
put_file "$repo" src/big.js 501
run_gate sid-g2 "$repo"
expect_decision "control: no marker, the same file blocks" block src/big.js
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
