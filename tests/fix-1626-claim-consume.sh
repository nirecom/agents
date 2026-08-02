#!/usr/bin/env bash
# tests/fix-1626-claim-consume.sh
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, bin/request-off-clearance, hooks/workflow-state/state-io/zombie-cleanup.js
# Tags: off-clearance, claim, toctou, concurrency, single-use, zombie-cleanup, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The shim firing as a real PreToolUse hook inside a live claude -p session, and
#   two REAL Claude turns racing for the same token (here both racers are node
#   subprocesses launched from one shell).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# #1626 — atomic claim redesign. The old design was two-step (shim validates,
# workflow-mark later consumes), which is TOCTOU-racy: two concurrent OFF
# proposals could both observe the same valid bare token and both be allowed.
# The redesign makes VALIDATION-SUCCESS ITSELF the claim:
#   hooks/supervisor-off-proposal-shim.js does fs.openSync(<sid>.off-clearance.claimed,
#   "wx", 0o600) — exclusive create, which throws EEXIST on BOTH POSIX and Windows —
#   and renames/claims the bare <sid>.off-clearance into it. Losing the wx race is a
#   block. hooks/workflow-mark/enforce-override-handlers/off-clearance.js is demoted to
#   bookkeeping-only (it may only unlink a .claimed file; it never validates or claims).
#   bin/request-off-clearance resets a stale .claimed at mint time.
#   cleanupZombies() sweeps old .claimed files.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
STATE_IO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
REQ="$AGENTS_DIR/bin/request-off-clearance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
# shellcheck source=./lib/examiner-stub.sh
. "$AGENTS_DIR/tests/lib/examiner-stub.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'claim1626'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

if [ ! -f "$SHIM" ]; then
    fail "supervisor-off-proposal-shim.js not present (harness error)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

WF_BOUND='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] next-step bug blocks progress>>"'

# write_bare <tmp_node> <sid> — mint a VALID bare clearance token (as request-off-clearance does)
write_bare() {
    "$RWT" 12 node -e "
const fs=require('fs'),path=require('path');
const p=path.join(process.argv[1], process.argv[2]+'.off-clearance');
fs.writeFileSync(p, JSON.stringify({target:'workflow',category:'workflow-bug',urgency:'normal',
  minted_at:new Date().toISOString(), expires_at:new Date(Date.now()+15*60000).toISOString(),
  verdict_reason:'examiner ALLOW', detail:'stub'}), {mode:0o600});" "$1" "$2" >/dev/null 2>&1
}

# write_claimed <tmp_node> <sid> — pre-existing (stale) .claimed file
write_claimed() {
    "$RWT" 12 node -e "
const fs=require('fs'),path=require('path');
const p=path.join(process.argv[1], process.argv[2]+'.off-clearance.claimed');
fs.writeFileSync(p, JSON.stringify({target:'workflow',category:'workflow-bug',urgency:'normal',
  minted_at:new Date().toISOString(), expires_at:new Date(Date.now()+15*60000).toISOString(),
  verdict_reason:'examiner ALLOW', detail:'stale claim',
  claimed_at:new Date().toISOString(), claimed_target:'workflow',
  claimed_reason:'[workflow-bug] a previous proposal'}), {mode:0o600});" "$1" "$2" >/dev/null 2>&1
}

# mk_input <sid> <cmd> — PreToolUse hook stdin JSON
mk_input() {
    "$RWT" 10 node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:process.argv[2]}}));" "$1" "$2"
}

# run_shim <tmp_node> <sid> <cmd> → prints "rc|<stdout>"
run_shim() {
    local tn="$1" sid="$2" cmd="$3" hi out rc
    hi=$(mk_input "$sid" "$cmd")
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" \
        "$RWT" 12 node "$SHIM" <<< "$hi" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

is_block() { echo "$1" | grep -q '"decision":"block"'; }
count_glob() { ls -1 $1 2>/dev/null | wc -l | tr -d ' '; }
file_hash() { "$RWT" 10 node -e "
const fs=require('fs'),c=require('crypto');
try{process.stdout.write(c.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'));}
catch(e){process.stdout.write('ABSENT');}" "$1" 2>/dev/null; }

# ---- case parts ------------------------------------------------------------

PARTS_DIR="$AGENTS_DIR/tests/fix-1626-claim-consume"

# shellcheck source=./fix-1626-claim-consume/cases-claim.sh
. "$PARTS_DIR/cases-claim.sh"
# shellcheck source=./fix-1626-claim-consume/cases-recovery.sh
. "$PARTS_DIR/cases-recovery.sh"

run_C1
run_C2
run_C3
run_C4
run_C5
run_C6
run_C7
run_C8
run_C9
run_C10
run_C11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
