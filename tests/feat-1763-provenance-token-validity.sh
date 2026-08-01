#!/usr/bin/env bash
# tests/feat-1763-provenance-token-validity.sh
# Tests: bin/github-issues/issue-provenance, hooks/lib/issue-provenance-keys.js, hooks/lib/session-markers.js
# Tags: issue-create, provenance, token, validity, binding, fail-closed, table-driven, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - A token written by the real hook in a live session (that is tests/TL3-hook-issue-provenance-mint.sh).
#   Here the tokens are hand-forged precisely so that malformed shapes the hook would
#   never produce can be exercised.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# S10a — the token is the ONLY thing that can promote a turn to `user-explicit`, which
# is the classification that SUPPRESSES the confirm gate (G3). So every deviation from
# a well-formed, correctly-bound, unexpired token must fail CLOSED to `mid-workflow`.
# The table below is the full deviation set; each row must degrade, never elevate.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
redc() { fail "$1" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"; }

CLI_PRESENT=no; [ -f "$CLI" ] && CLI_PRESENT=yes

WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

SID="cc-session-validity"

# new_env <name> → base with a workflow dir, plans dir, cwd and a transcript whose
# newest user entry is NOT an issue request. That matters: with layers B and C ruled
# out, `user-explicit` can only come from the token, so each row isolates the token.
new_env() {
    local base="$WORK/$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd" "$base/outside"
    printf 'Session-ID: %s\n' "$SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$SID-intent.md"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"run the tests please"}}' > "$base/transcript.jsonl"
    printf '%s' "$(node_path "$base/transcript.jsonl")" > "$base/state/$SID.session-transcript"
    # A workflow state marking the session active, so layer C cannot fire either.
    # "Active" means PART WAY through, so the fixture needs both halves: a step already
    # off `pending` AND a step not yet terminal. An all-complete state is a FINISHED
    # workflow, which reads inactive — layer C would then grant `user-explicit` on its
    # own and every row below would pass or fail for a reason unrelated to its token.
    printf '%s' '{"steps":{"research":{"status":"complete"},"write_code":{"status":"pending"}}}' \
        > "$base/state/$SID.json"
    printf 'canary\n' > "$base/outside/untouched.txt"
    printf '%s' "$base"
}

# write_token <base> <json-literal>
write_token() { printf '%s' "$2" > "$1/state/$SID.issue-provenance"; }

# consume <base> [session-id-override] → sets VERDICT / LAYER / RC
consume() {
    local base="$1" sid="${2:-$SID}"
    [ "$CLI_PRESENT" = "yes" ] || { VERDICT="<missing>"; LAYER="<missing>"; RC=127; return; }
    VERDICT=$( ( cd "$base/cwd" && env \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 20 bash "$CLI" --consume 2>"$base/stderr.txt" ) )
    RC=$?
    VERDICT=$(printf '%s' "$VERDICT" | tr -d '[:space:]')
    LAYER=$(sed -n 's/^layer: *//p' "$base/stderr.txt" 2>/dev/null | head -n 1 | tr -d '[:space:]')
}

FUTURE=$(node -e "process.stdout.write(new Date(Date.now()+600000).toISOString())")
PAST=$(node -e "process.stdout.write(new Date(Date.now()-600000).toISOString())")
FAR=$(node -e "process.stdout.write(new Date(Date.now()+86400000*3650).toISOString())")

ELEVATIONS=0
ROWS=0

# assert_closed <name> <token-json>
# Each row asserts the SAME outcome, because "fail closed" means every deviation
# collapses to the unprivileged classification — no per-defect special casing.
assert_closed() {
    local name="$1" tok="$2"
    ROWS=$((ROWS + 1))
    local B; B=$(new_env "$name")
    write_token "$B" "$tok"
    consume "$B"
    if [ "$VERDICT" = "<missing>" ]; then redc "$name"; return; fi
    if [ "$RC" -ne 0 ]; then
        fail "$name" "the CLI must always exit 0 (got $RC)"
    elif [ "$VERDICT" != "mid-workflow" ]; then
        ELEVATIONS=$((ELEVATIONS + 1))
        fail "$name" "an invalid token must not elevate provenance (got: $VERDICT, layer=$LAYER)"
    elif [ "$(cat "$B/outside/untouched.txt")" != "canary" ]; then
        fail "$name" "a file outside the workflow directory was modified"
    else
        pass "$name"
    fi
}

echo "=== V0: positive control — a well-formed, bound, unexpired token DOES elevate ==="
# Without this, every assert_closed row below could pass for the wrong reason
# (e.g. the CLI unconditionally returning mid-workflow).
B=$(new_env v0)
write_token "$B" "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"match_layer\":\"slash\",\"expires_at\":\"$FUTURE\"}"
consume "$B"
if [ "$VERDICT" = "<missing>" ]; then
    redc "V0-valid-token-elevates"; redc "V0-layer-A"
else
    [ "$VERDICT" = "user-explicit" ] && pass "V0-valid-token-elevates" \
        || fail "V0-valid-token-elevates" "a valid token must yield user-explicit (got: $VERDICT, layer=$LAYER)"
    [ "$LAYER" = "A" ] && pass "V0-layer-A" || fail "V0-layer-A" "want layer A (got: '${LAYER:-<none>}')"
fi

echo ""
echo "=== V1: target binding — a token minted for another consumer must not be accepted ==="
assert_closed V1a-target-other        "{\"target\":\"issue-close\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V1b-target-absent       "{\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V1c-target-null         "{\"target\":null,\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V1d-target-wrong-type   "{\"target\":[\"issue-create\"],\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V1e-target-substring    "{\"target\":\"issue-create-x\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"

echo ""
echo "=== V2: provenance value — only the exact enum member may elevate ==="
assert_closed V2a-provenance-unknown  "{\"target\":\"issue-create\",\"provenance\":\"admin\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V2b-provenance-absent   "{\"target\":\"issue-create\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V2c-provenance-empty    "{\"target\":\"issue-create\",\"provenance\":\"\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V2d-provenance-case     "{\"target\":\"issue-create\",\"provenance\":\"User-Explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"
assert_closed V2e-provenance-boolean  "{\"target\":\"issue-create\",\"provenance\":true,\"session_id\":\"$SID\",\"expires_at\":\"$FUTURE\"}"

echo ""
echo "=== V3: expiry — absent, unparseable, wrong-typed, past, and implausibly far ==="
assert_closed V3a-expires-absent      "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\"}"
assert_closed V3b-expires-unparseable "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"soon\"}"
assert_closed V3c-expires-number      "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":1893456000000}"
assert_closed V3d-expires-null        "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":null}"
assert_closed V3e-expires-past        "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$PAST\"}"
# A 10-year expiry is indistinguishable from "never expires" — the whole point of the
# turn-boundary binding is that the window is short, so it must not be honoured.
assert_closed V3f-expires-far-future  "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$FAR\"}"

echo ""
echo "=== V4: session binding — a token belonging to another session must not be accepted ==="
assert_closed V4a-session-other       "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"cc-session-somebody-else\",\"expires_at\":\"$FUTURE\"}"
assert_closed V4b-session-absent      "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"expires_at\":\"$FUTURE\"}"
assert_closed V4c-session-null        "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":null,\"expires_at\":\"$FUTURE\"}"

echo ""
echo "=== V5: corrupt or degenerate token content ==="
assert_closed V5a-corrupt-json        '{"target":"issue-create","provenance":'
assert_closed V5b-empty-file          ''
assert_closed V5c-not-an-object       '"user-explicit"'
assert_closed V5d-json-array          '[{"target":"issue-create","provenance":"user-explicit"}]'
assert_closed V5e-null-literal        'null'
assert_closed V5f-whitespace-only     '   '

echo ""
echo "=== V6: a session id carrying path separators cannot redirect the token read ==="
# The session id reaches a filesystem path. If it were interpolated unsanitised, a
# traversal id would read a token the caller planted outside the workflow directory.
if [ "$CLI_PRESENT" != "yes" ]; then
    redc "V6a-traversal-sid-fails-closed"; redc "V6b-traversal-sid-no-outside-read"; redc "V6c-separator-sid-fails-closed"
else
    B=$(new_env v6)
    # Plant a perfectly valid token one level ABOVE the workflow directory.
    mkdir -p "$B/planted"
    printf '%s' "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"../planted/x\",\"expires_at\":\"$FUTURE\"}" \
        > "$B/planted/x.issue-provenance"
    consume "$B" "../planted/x"
    [ "$RC" -eq 0 ] && [ "$VERDICT" = "mid-workflow" ] && pass "V6a-traversal-sid-fails-closed" \
        || fail "V6a-traversal-sid-fails-closed" "a traversal session id must fail closed (rc=$RC verdict=$VERDICT)"
    # And nothing may be written next to the planted file.
    if [ "$(find "$B/planted" -type f | wc -l | tr -d ' ')" = "1" ]; then
        pass "V6b-traversal-sid-no-outside-read"
    else
        fail "V6b-traversal-sid-no-outside-read" "the consume path created files outside the workflow directory"
    fi

    B=$(new_env v6b)
    write_token "$B" "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"a/b\",\"expires_at\":\"$FUTURE\"}"
    consume "$B" "a/b"
    [ "$RC" -eq 0 ] && [ "$VERDICT" = "mid-workflow" ] && pass "V6c-separator-sid-fails-closed" \
        || fail "V6c-separator-sid-fails-closed" "a session id containing a path separator must fail closed (rc=$RC verdict=$VERDICT)"
fi

echo ""
echo "=== V7: an unreadable token directory still fails closed at exit 0 ==="
if [ "$CLI_PRESENT" != "yes" ]; then
    redc "V7-unreadable-token-fails-closed"
else
    B=$(new_env v7)
    # A directory where the token file is expected: every read attempt errors.
    rm -f "$B/state/$SID.issue-provenance"
    mkdir -p "$B/state/$SID.issue-provenance"
    consume "$B"
    [ "$RC" -eq 0 ] && [ "$VERDICT" = "mid-workflow" ] && pass "V7-unreadable-token-fails-closed" \
        || fail "V7-unreadable-token-fails-closed" "an unreadable token must fail closed at exit 0 (rc=$RC verdict=$VERDICT)"
fi

echo ""
echo "=== V8: a rejected token is still cleared, so it cannot be retried ==="
# Leaving an invalid token on disk would let a later turn (with a different clock or
# a patched validator) pick it up. Consumption is destructive regardless of verdict.
if [ "$CLI_PRESENT" != "yes" ]; then
    redc "V8-invalid-token-cleared"
else
    B=$(new_env v8)
    write_token "$B" "{\"target\":\"issue-create\",\"provenance\":\"user-explicit\",\"session_id\":\"$SID\",\"expires_at\":\"$PAST\"}"
    consume "$B"
    [ ! -f "$B/state/$SID.issue-provenance" ] && pass "V8-invalid-token-cleared" \
        || fail "V8-invalid-token-cleared" "a rejected token must not be left on disk for a retry"
fi

echo ""
echo "=== V9: no row ever elevated — the whole table degrades in one direction ==="
# A single summary assertion over the run: if any deviation had elevated, one of the
# rows above would already have failed. This states the invariant explicitly so a
# future reader cannot mistake the table for a list of independent quirks.
if [ "$CLI_PRESENT" != "yes" ]; then
    redc "V9-monotonic-degradation"
else
    if [ "$ROWS" -lt 20 ]; then
        fail "V9-monotonic-degradation" "only $ROWS deviation rows ran — the table is incomplete"
    elif [ "$ELEVATIONS" -eq 0 ]; then
        pass "V9-monotonic-degradation"
    else
        fail "V9-monotonic-degradation" "$ELEVATIONS of $ROWS deviations elevated provenance"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
