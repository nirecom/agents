#!/usr/bin/env bash
# tests/feat-1763-provenance-sid-keying.sh
# Tests: bin/github-issues/issue-provenance, hooks/issue-provenance-mint.js, hooks/lib/issue-provenance-keys.js, hooks/lib/session-markers.js, hooks/session-start.js
# Tags: issue-create, provenance, session-id, keying, transcript-pointer, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real session_id Claude Code passes to hooks, and the real transcript_path it points at.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# S12 — the keying hazard. Two different session identifiers coexist:
#   * CC session UUID   — resolveSessionId()          ← hook payload / CLAUDE_CODE_SESSION_ID
#   * workflow session  — resolveWorkflowSessionId()  ← WORKTREE_NOTES.md "Session-ID:" in CWD
# The provenance markers are hook-minted, so they MUST be keyed on the CC session UUID
# on both the write side (mint hook) and the read side (issue-provenance --consume).
# Every case below pins the two identifiers to deliberately DIFFERENT values so that a
# mis-keyed read silently reports mid-workflow instead of accidentally passing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
MINT="$AGENTS_DIR/hooks/issue-provenance-mint.js"
KEYS="$AGENTS_DIR/hooks/lib/issue-provenance-keys.js"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

CC_SID="11111111-2222-3333-4444-555555555555"   # CC session UUID (hook payload)
WF_SID="20260731-120000"                        # workflow session ID (WORKTREE_NOTES.md)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# new_env <name> → prints base dir. CC SID and workflow SID are deliberately different.
new_env() {
    local base="$WORK/$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$WF_SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$WF_SID-intent.md"
    : > "$base/transcript.jsonl"
    printf '%s' "$base"
}

add_user() { TXT="$2" node -e "process.stdout.write(JSON.stringify({type:'user',message:{role:'user',content:process.env.TXT}}))" >> "$1/transcript.jsonl"; printf '\n' >> "$1/transcript.jsonl"; }

# run_mint <base> <prompt> → feeds a UserPromptSubmit payload keyed on CC_SID
run_mint() {
    local base="$1" prompt="$2"
    [ -f "$MINT" ] || { MINT_RC=127; return; }
    local payload
    payload=$(SID="$CC_SID" P="$prompt" T="$(node_path "$base/transcript.jsonl")" C="$(node_path "$base/cwd")" \
        node -e "process.stdout.write(JSON.stringify({session_id:process.env.SID,prompt:process.env.P,transcript_path:process.env.T,cwd:process.env.C,hook_event_name:'UserPromptSubmit'}))")
    printf '%s' "$payload" | ( cd "$base/cwd" && \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 20 node "$MINT" >/dev/null 2>&1 )
    MINT_RC=$?
}

# consume <base> [ccsid-override] → sets VERDICT / LAYER
consume() {
    local base="$1" sid="${2:-$CC_SID}"
    if [ ! -f "$CLI" ]; then VERDICT="<missing>"; LAYER="<missing>"; return; fi
    local errf="$base/consume-stderr.txt"
    VERDICT=$( cd "$base/cwd" && \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 25 bash "$CLI" --consume 2>"$errf" | tr -d '[:space:]' )
    LAYER=$(grep -oE 'layer: *[A-Za-z]+' "$errf" 2>/dev/null | tail -n 1 | sed 's/.*: *//')
}

echo "=== S1: the mint hook keys marker files on the CC session UUID, not the workflow SID ==="
B=$(new_env s1)
run_mint "$B" "/issue-create the parser drops trailing commas"
if [ ! -f "$MINT" ]; then
    fail "S1-token-keyed-on-cc-sid" "RED-EXPECTED: hooks/issue-provenance-mint.js not yet created"
    fail "S2-no-workflow-sid-keyed-file" "RED-EXPECTED: hooks/issue-provenance-mint.js not yet created"
else
    if [ -f "$B/state/$CC_SID.issue-provenance" ]; then
        pass "S1-token-keyed-on-cc-sid"
    else
        fail "S1-token-keyed-on-cc-sid" "expected <workflowDir>/$CC_SID.issue-provenance (present: $(ls "$B/state" 2>/dev/null | tr '\n' ' '))"
    fi
    if [ -f "$B/state/$WF_SID.issue-provenance" ]; then
        fail "S2-no-workflow-sid-keyed-file" "the marker was keyed on the workflow SID ($WF_SID) — read side uses the CC UUID"
    else
        pass "S2-no-workflow-sid-keyed-file"
    fi
fi

echo ""
echo "=== S3: --consume reads the CC-SID-keyed token (write/read keying agrees) ==="
consume "$B"
if [ "$VERDICT" = "<missing>" ]; then
    fail "S3-consume-reads-cc-sid-token" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"
elif [ "$VERDICT" = "user-explicit" ]; then
    pass "S3-consume-reads-cc-sid-token (layer=${LAYER:-?})"
else
    fail "S3-consume-reads-cc-sid-token" "want user-explicit from the minted token, got '$VERDICT' (layer=${LAYER:-none}) — keying mismatch"
fi

echo ""
echo "=== S4: a token minted under a DIFFERENT CC session is never read ==="
B=$(new_env s4)
run_mint "$B" "/issue-create cross-session leak check"
consume "$B" "99999999-8888-7777-6666-555555555555"
if [ "$VERDICT" = "<missing>" ]; then
    fail "S4-cross-session-token-not-read" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"
elif [ "$VERDICT" = "mid-workflow" ]; then
    pass "S4-cross-session-token-not-read"
else
    fail "S4-cross-session-token-not-read" "another session's token was honoured (got '$VERDICT')"
fi

echo ""
echo "=== S5: observation point 2 recovers the transcript from the session-transcript pointer ==="
# No token: the CLI must locate the transcript through <ccsid>.session-transcript,
# which is written by the mint hook (every turn) and by session-start.js.
B=$(new_env s5)
add_user "$B" "please open an issue for the pointer recovery path"
printf '%s' "$(node_path "$B/transcript.jsonl")" > "$B/state/$CC_SID.session-transcript"
consume "$B"
if [ "$VERDICT" = "<missing>" ]; then
    fail "S5-transcript-pointer-recovery" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"
elif [ "$VERDICT" = "user-explicit" ]; then
    pass "S5-transcript-pointer-recovery (layer=${LAYER:-?})"
else
    fail "S5-transcript-pointer-recovery" "want user-explicit via the pointer, got '$VERDICT' (layer=${LAYER:-none})"
fi

echo ""
echo "=== S6: a pointer keyed on the workflow SID is NOT used ==="
B=$(new_env s6)
add_user "$B" "please open an issue for the mis-keyed pointer"
printf '%s' "$(node_path "$B/transcript.jsonl")" > "$B/state/$WF_SID.session-transcript"
consume "$B"
if [ "$VERDICT" = "<missing>" ]; then
    fail "S6-workflow-sid-pointer-ignored" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"
elif [ "$VERDICT" = "mid-workflow" ]; then
    pass "S6-workflow-sid-pointer-ignored"
else
    fail "S6-workflow-sid-pointer-ignored" "a workflow-SID-keyed pointer was consumed (got '$VERDICT'); markers are CC-SID-keyed"
fi

echo ""
echo "=== S7: issue-provenance-keys.js derives all 3 paths from ONE session id (SSOT) ==="
if [ ! -f "$KEYS" ]; then
    fail "S7-keys-single-source" "RED-EXPECTED: hooks/lib/issue-provenance-keys.js not yet created"
    fail "S8-keys-suffixes"      "RED-EXPECTED: hooks/lib/issue-provenance-keys.js not yet created"
else
    OUT=$("$RWT" 12 node -e "
try {
  const m = require(process.argv[1]);
  const p = m.provenancePaths ? m.provenancePaths('SIDX', process.argv[2]) : null;
  if (!p) { process.stdout.write('no-provenancePaths'); process.exit(0); }
  const vals = Object.values(p).map(String);
  const allKeyed = vals.every(v => v.includes('SIDX'));
  process.stdout.write((allKeyed ? 'keyed' : 'unkeyed') + '|' + vals.join(','));
} catch (e) { process.stdout.write('err:' + e.message); }" "$(node_path "$KEYS")" "$(node_path "$WORK")" 2>/dev/null)
    case "$OUT" in
        keyed\|*) pass "S7-keys-single-source" ;;
        *) fail "S7-keys-single-source" "provenancePaths(sid, dir) must key every path on the given sid (got: $OUT)" ;;
    esac
    MISSING=""
    for suf in .issue-provenance .issue-provenance-consumed .session-transcript; do
        printf '%s' "$OUT" | grep -qF "SIDX$suf" || MISSING="$MISSING $suf"
    done
    if [ -z "$MISSING" ]; then
        pass "S8-keys-suffixes"
    else
        fail "S8-keys-suffixes" "missing path(s):$MISSING (got: $OUT)"
    fi
fi

echo ""
echo "=== S9: the mint hook and the CLI both resolve keys through issue-provenance-keys.js ==="
for f in "$MINT" "$CLI"; do
    label="S9-$(basename "$f")-uses-keys-module"
    if [ ! -f "$f" ]; then
        fail "$label" "RED-EXPECTED: $(basename "$f") not yet created"
    elif grep -qF 'issue-provenance-keys' "$f"; then
        pass "$label"
    else
        fail "$label" "must derive marker paths from hooks/lib/issue-provenance-keys.js (CPR-2), not build them inline"
    fi
done

echo ""
echo "=== S10: session-start.js writes the <ccsid>.session-transcript pointer ==="
# Spawned for real rather than grepped: a source match would be satisfied by a comment,
# a dead branch, or a path keyed on the wrong session id — which is precisely the
# failure this section exists to catch.
if [ ! -f "$SESSION_START" ]; then
    for t in S10a-pointer-written S10b-pointer-content S10c-not-workflow-sid-keyed S10d-hook-exits-0; do
        fail "$t" "hooks/session-start.js not found"
    done
else
    B=$(new_env s10)
    TP="$B/real-transcript.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$TP"
    PAYLOAD=$(TP="$(node_path "$TP")" node -e "
process.stdout.write(JSON.stringify({ session_id: '$CC_SID', transcript_path: process.env.TP,
  cwd: process.argv[1], hook_event_name: 'SessionStart', source: 'startup' }));" "$(node_path "$B/cwd")")
    ( cd "$B/cwd" && env \
        CLAUDE_WORKFLOW_DIR="$(node_path "$B/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$B/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        CLAUDE_CODE_SESSION_ID="$CC_SID" \
        "$RWT" 20 node "$SESSION_START" <<< "$PAYLOAD" >"$B/ss-stdout.txt" 2>"$B/ss-stderr.txt" )
    SS_RC=$?

    PTR="$B/state/$CC_SID.session-transcript"
    if [ -f "$PTR" ]; then
        pass "S10a-pointer-written"
        GOT=$(tr -d '\r\n' < "$PTR")
        WANT=$(node_path "$TP")
        # Compare case-insensitively: on Windows the drive letter casing differs
        # between cygpath output and node's own path handling.
        if [ "$(printf '%s' "$GOT" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$WANT" | tr 'A-Z' 'a-z')" ]; then
            pass "S10b-pointer-content"
        else
            fail "S10b-pointer-content" "the pointer must hold the supplied transcript_path (want='$WANT' got='$GOT')"
        fi
    else
        fail "S10a-pointer-written" "RED-EXPECTED: session-start.js did not write $CC_SID.session-transcript"
        fail "S10b-pointer-content" "RED-EXPECTED: no pointer file to inspect"
    fi

    # The workflow session id is present in CWD's WORKTREE_NOTES.md, so a hook that
    # resolved the wrong identifier would still produce a plausible-looking file.
    if [ -f "$B/state/$WF_SID.session-transcript" ]; then
        fail "S10c-not-workflow-sid-keyed" "the pointer was keyed on the workflow session id ($WF_SID)"
    else
        pass "S10c-not-workflow-sid-keyed"
    fi

    [ "$SS_RC" -eq 0 ] && pass "S10d-hook-exits-0" \
        || fail "S10d-hook-exits-0" "a SessionStart hook must never fail the session (rc=$SS_RC: $(head -n 1 "$B/ss-stderr.txt"))"
fi

echo ""
echo "=== S11: session-markers.js reads provenance with the resolved CC session id ==="
SM="$AGENTS_DIR/hooks/lib/session-markers.js"
if grep -qE 'readIssueProvenance' "$SM" 2>/dev/null; then
    if grep -qE 'resolveWorkflowSessionId' "$SM" && ! grep -qE 'resolveSessionId' "$SM"; then
        fail "S11-session-markers-cc-keyed" "provenance readers must not key on the workflow session id"
    else
        pass "S11-session-markers-cc-keyed"
    fi
else
    fail "S11-session-markers-cc-keyed" "RED-EXPECTED: session-markers.js has no readIssueProvenance yet"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
