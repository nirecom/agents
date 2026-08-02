#!/usr/bin/env bash
# tests/fix-1780-round14-mint-lock.sh
# Tests: hooks/lib/off-clearance-mint-lock.js, hooks/supervisor-off-proposal-shim.js, bin/request-off-clearance, hooks/lib/protected-basenames.js, hooks/block-off-clearance-write.js
# Tags: off-clearance, mint-lock, concurrency, race, toctou, claim, audit-trail, fail-closed, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The shim running as a REAL PreToolUse hook while a REAL bin/request-off-clearance
#   mint runs in another live Claude Code session. Here the "other participant" is a
#   pre-placed lock file / a background node process, which reproduces the lock
#   STATE faithfully but not the OS-level interleaving of two independent sessions.
# - A hard crash (SIGKILL) mid-critical-section, where no `finally` runs and the
#   24h transient sweep in zombie-cleanup.js is the only thing that frees the lock.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# #1780 round-14 — WHY THIS FILE EXISTS.
#
# Three separate defects share one root cause and are pinned here together
# (CPR-3 — they are separated by WHERE they act, not merged into one blob):
#
#   HIGH  — MINT/CLAIM RACE. bin/request-off-clearance's mint transition and the
#           shim's claim lifecycle mutate the SAME bare-token/claim pair for one
#           SID from two processes. Unsynchronized, a mint can destroy a fresh
#           grant (shim unlinks the bare path BY NAME after a newer mint wrote
#           it) or a mint's stale-claim sweep can delete a claim that is being
#           created right now. hooks/lib/off-clearance-mint-lock.js is the shared
#           mutex; the shim taking it — and RE-READING the token inside it — is
#           the fix. Cases L*/S*.
#   HIGH-2 — the lock file itself (`<token>.mint.lock.tmp`) sits beside live
#           clearance state and is trivially forgeable: pre-create it and every
#           future claim for that SID times out (a self-DoS on the OFF path), or
#           delete it mid-transition and the mutex evaporates. It must therefore
#           be protected by the same basename SSOT as the token. Cases P*.
#   MEDIUM — bin/request-off-clearance defined append_audit/emergency_hint AFTER
#           the WORKFLOW_DIR resolution, so a failure IN that resolution exited
#           silently under `set -euo pipefail`: no UNAVAILABLE audit record, no
#           emergency guidance. This command IS the recovery path when
#           enforcement is broken, so a silent exit leaves the operator with
#           nothing at all. Cases R*.
#
# WHAT WOULD MAKE THESE TESTS PASS VACUOUSLY: a lock that is never contended.
# Every contention case below therefore establishes the contended state
# EXPLICITLY (pre-created lock file / background holder) and asserts the
# fail-CLOSED outcome, not merely "no crash".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

LOCK_MOD_NODE="$_AGENTS_DIR_NODE/hooks/lib/off-clearance-mint-lock.js"
BASENAMES_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
BLOCK_HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
REQ="$AGENTS_DIR/bin/request-off-clearance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'mintlock1780'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# assert_eq <label> <want> <got>
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 -> $3"; else fail "$1 want=$2 got=$3"; fi
}
# assert_has <label> <needle> <haystack>
assert_has() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1 (missing: $2) [got=$(printf '%s' "$3" | head -c 220)]" ;;
    esac
}
# assert_not_has <label> <needle> <haystack>
assert_not_has() {
    case "$3" in
        *"$2"*) fail "$1 (unexpectedly present: $2)" ;;
        *) pass "$1" ;;
    esac
}
# field <key> <kv-output> — pull `key=value` (value = rest of line) out of a KEY=VALUE dump
field() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1 | tr -d '\r'; }

# The session id used throughout. Kept ASCII-simple: SID_RE in both the shim and
# request-off-clearance is ^[A-Za-z0-9_-]+$, and a rejected SID would make every
# case below block for the WRONG reason.
SID="mintlocksid"

# A reason-bound OFF sentinel whose category (`workflow-bug`) matches the token
# minted by write_bare_token below — evaluateOffClearance() binds the two.
WF_BOUND='echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] next-step bug blocks progress>>"'

# write_bare_token <dir_node> <sid> <nonce> [ttl_min] — mint a VALID bare token,
# shaped as bin/request-off-clearance mints it. <nonce> lands in mint_nonce so a
# case can prove WHICH bytes a later read saw.
write_bare_token() {
    "$RWT" 12 node -e '
const fs=require("fs"),path=require("path");
const ttl=Number(process.argv[4]||15);
fs.writeFileSync(path.join(process.argv[1], process.argv[2]+".off-clearance"), JSON.stringify({
  target:"workflow", category:"workflow-bug", urgency:"normal",
  minted_at:new Date().toISOString(),
  expires_at:new Date(Date.now()+ttl*60000).toISOString(),
  mint_nonce:process.argv[3],
  verdict_reason:"examiner ALLOW", detail:"stub"}), {mode:0o600});' "$1" "$2" "$3" "${4:-15}" >/dev/null 2>&1
}

# mk_shim_input <sid> <cmd> — PreToolUse stdin JSON for the shim
mk_shim_input() {
    "$RWT" 10 node -e '
process.stdout.write(JSON.stringify({tool_name:"Bash",session_id:process.argv[1],tool_input:{command:process.argv[2]}}));' "$1" "$2"
}

# run_shim <dir_node> <sid> <cmd> → "<rc>|<stdout>"
run_shim() {
    local tn="$1" sid="$2" cmd="$3" hi out rc
    hi=$(mk_shim_input "$sid" "$cmd")
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 20 node "$SHIM" <<< "$hi" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# read_json_field <file> <key> → the value, or ABSENT
read_json_field() {
    "$RWT" 10 node -e '
const fs=require("fs");
try { const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const v=o[process.argv[2]];
  process.stdout.write(v===undefined?"ABSENT":String(v)); }
catch(e){ process.stdout.write("ABSENT"); }' "$1" "$2" 2>/dev/null
}

exists_str() { [ -e "$1" ] && printf 'yes' || printf 'no'; }

if [ ! -f "$SHIM" ] || [ ! -f "$AGENTS_DIR/hooks/lib/off-clearance-mint-lock.js" ]; then
    fail "mint-lock module or shim not present (harness error)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# shellcheck source=./lib/examiner-stub.sh
. "$AGENTS_DIR/tests/lib/examiner-stub.sh"

PARTS_DIR="$AGENTS_DIR/tests/fix-1780-round14-mint-lock"
# shellcheck source=./fix-1780-round14-mint-lock/cases-lock-primitive.sh
. "$PARTS_DIR/cases-lock-primitive.sh"
# shellcheck source=./fix-1780-round14-mint-lock/cases-lock-protected.sh
. "$PARTS_DIR/cases-lock-protected.sh"
# shellcheck source=./fix-1780-round14-mint-lock/cases-shim-lock.sh
. "$PARTS_DIR/cases-shim-lock.sh"
# shellcheck source=./fix-1780-round14-mint-lock/cases-cli-failure.sh
. "$PARTS_DIR/cases-cli-failure.sh"

run_L_lock_primitive    # the mutex itself: exclusivity, budget, release, fault
run_P_lock_protected    # the lock FILE is protected state, by the same SSOT
run_S_shim_lock         # the shim's claim lifecycle runs under that mutex
run_R_cli_wfdir_failure # a WORKFLOW_DIR failure is AUDITED, not silent

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
