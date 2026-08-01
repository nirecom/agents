#!/usr/bin/env bash
# tests/feat-1763-provenance-token.sh
# Tests: hooks/issue-provenance-mint.js, hooks/lib/issue-provenance-keys.js, hooks/lib/session-markers.js, bin/github-issues/issue-provenance
# Tags: issue-create, provenance, userpromptsubmit, hook, token, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code actually fires UserPromptSubmit for this hook in a live
#   session (that is tests/TL3-hook-issue-provenance-mint.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# S9/S10a/S10b — observation point 1. The hook mints a provenance token on an
# explicit issue-creation request, revokes it on any other turn (turn-boundary
# binding), always refreshes the <sid>.session-transcript pointer, and is a no-op
# when ISSUE_PROVENANCE=off. The hook's stdout is always "{}".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
HOOK="$AGENTS_DIR/hooks/issue-provenance-mint.js"
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes
CLI_PRESENT=no;  [ -f "$CLI" ]  && CLI_PRESENT=yes
redh() { fail "$1" "RED-EXPECTED: hooks/issue-provenance-mint.js not yet created"; }
redc() { fail "$1" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SID="cc-session-aaaa"

# new_env <name> → base dir with state/, plans/, cwd/ and a transcript fixture
new_env() {
    local base="$WORK/$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$SID-intent.md"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$base/transcript.jsonl"
    printf '%s' "$base"
}

# fire_hook <base> <prompt> [extra env assignments...] → hook stdout
fire_hook() {
    local base="$1" prompt="$2"; shift 2
    [ "$HOOK_PRESENT" = "yes" ] || { printf '<missing>'; return; }
    local payload
    payload=$(PROMPT="$prompt" TP="$(node_path "$base/transcript.jsonl")" node -e "
process.stdout.write(JSON.stringify({
  session_id: '$SID', prompt: process.env.PROMPT,
  transcript_path: process.env.TP, cwd: process.argv[1]
}));" "$(node_path "$base/cwd")" 2>/dev/null)
    # Config pinning (rules/test.md): the defaults are declared here rather than
    # inherited from the developer's .env; caller-supplied assignments come after
    # them, so a case can still pin `off` for itself (T5 does).
    ( cd "$base/cwd" && env ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off "$@" \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        CLAUDE_CODE_SESSION_ID="$SID" \
        "$RWT" 15 node "$HOOK" <<< "$payload" 2>/dev/null )
}

token_path() { printf '%s' "$1/state/$SID.issue-provenance"; }
transcript_ptr() { printf '%s' "$1/state/$SID.session-transcript"; }

# tok_q <base> <node-expr over `t`>
tok_q() {
    local f; f="$(token_path "$1")"
    [ -f "$f" ] || { printf 'no-token'; return; }
    "$RWT" 12 node -e "
try { const t = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const v = ($2); process.stdout.write(String(v));
} catch (e) { process.stdout.write('parse-error'); }" "$(node_path "$f")" 2>/dev/null
}

echo "=== T1: layer A (slash form) mints a token ==="
B=$(new_env t1)
OUT=$(fire_hook "$B" "/issue-create the flaky hook")
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T1-token-created"; redh "T1-target"; redh "T1-match-layer-slash"; redh "T1-expires-in-future"; redh "T1-stdout-empty-object"
else
    [ -f "$(token_path "$B")" ] && pass "T1-token-created" || fail "T1-token-created" "no token at $(token_path "$B")"
    T=$(tok_q "$B" "t.target");   [ "$T" = "issue-create" ] && pass "T1-target" || fail "T1-target" "want target 'issue-create' (got: $T)"
    T=$(tok_q "$B" "t.match_layer"); [ "$T" = "slash" ] && pass "T1-match-layer-slash" || fail "T1-match-layer-slash" "want match_layer 'slash' (got: $T)"
    T=$(tok_q "$B" "Date.parse(t.expires_at) > Date.now()"); [ "$T" = "true" ] && pass "T1-expires-in-future" \
        || fail "T1-expires-in-future" "expires_at must be in the future (got: $T)"
    [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "{}" ] && pass "T1-stdout-empty-object" \
        || fail "T1-stdout-empty-object" "the hook must always print {} (got: $OUT)"
fi

echo ""
echo "=== T2: layer B (natural language) mints a token ==="
B=$(new_env t2)
fire_hook "$B" "この件、チケット起票しておいて" >/dev/null
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T2-token-created"; redh "T2-match-layer-natural"
else
    [ -f "$(token_path "$B")" ] && pass "T2-token-created" || fail "T2-token-created" "no token minted for a natural-language request"
    T=$(tok_q "$B" "t.match_layer"); [ "$T" = "natural" ] && pass "T2-match-layer-natural" \
        || fail "T2-match-layer-natural" "want match_layer 'natural' (got: $T)"
fi

echo ""
echo "=== T3: an unrelated turn revokes an existing token (turn-boundary binding) ==="
B=$(new_env t3)
fire_hook "$B" "/issue-create first turn" >/dev/null
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T3-token-exists-before"; redh "T3-token-revoked-after"
else
    [ -f "$(token_path "$B")" ] && pass "T3-token-exists-before" || fail "T3-token-exists-before" "precondition: no token after the minting turn"
    fire_hook "$B" "run the tests please" >/dev/null
    [ -f "$(token_path "$B")" ] && fail "T3-token-revoked-after" "the token survived a non-request turn" || pass "T3-token-revoked-after"
fi

echo ""
echo "=== T4: the transcript pointer is refreshed on every turn ==="
B=$(new_env t4)
fire_hook "$B" "just a normal message" >/dev/null
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T4-transcript-pointer-written"; redh "T4-transcript-pointer-content"
else
    if [ -f "$(transcript_ptr "$B")" ]; then
        pass "T4-transcript-pointer-written"
        if grep -qF "transcript.jsonl" "$(transcript_ptr "$B")"; then pass "T4-transcript-pointer-content"
        else fail "T4-transcript-pointer-content" "pointer does not reference the payload transcript_path"; fi
    else
        fail "T4-transcript-pointer-written" "no <sid>.session-transcript pointer even on a non-request turn"
        fail "T4-transcript-pointer-content" "no <sid>.session-transcript pointer even on a non-request turn"
    fi
fi

echo ""
echo "=== T5: ISSUE_PROVENANCE=off is a full no-op ==="
B=$(new_env t5)
OUT=$(fire_hook "$B" "/issue-create off case" ISSUE_PROVENANCE=off)
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T5-no-token-when-off"; redh "T5-no-pointer-when-off"; redh "T5-stdout-empty-object-when-off"
else
    [ -f "$(token_path "$B")" ] && fail "T5-no-token-when-off" "a token was minted although ISSUE_PROVENANCE=off" || pass "T5-no-token-when-off"
    [ -f "$(transcript_ptr "$B")" ] && fail "T5-no-pointer-when-off" "a transcript pointer was written although ISSUE_PROVENANCE=off" || pass "T5-no-pointer-when-off"
    [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "{}" ] && pass "T5-stdout-empty-object-when-off" \
        || fail "T5-stdout-empty-object-when-off" "the hook must always print {} (got: $OUT)"
fi

echo ""
echo "=== T5b: ISSUE_PROVENANCE=off still REVOKES a token minted while it was on ==="
# "Off is a no-op" is only half the contract, and the wrong half on its own. Minting is
# suppressed (T5), but returning early would leave a token that was minted while the
# switch was on sitting on disk with 15 minutes of validity left — so turning the
# mechanism OFF would be what keeps a live grant alive. Off must be at least as
# restrictive as on, never less: the revocation half of the turn boundary still runs.
B=$(new_env t5b)
fire_hook "$B" "/issue-create minted while on" >/dev/null
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T5b-precondition-token-exists"; redh "T5b-off-revokes-existing-token"
else
    if [ -f "$(token_path "$B")" ]; then
        pass "T5b-precondition-token-exists"
    else
        fail "T5b-precondition-token-exists" "precondition: no token to revoke"
    fi
    # Same session, next turn, switch now off. The prompt is itself a request, so the
    # only thing that can remove the token is the off path running revocation.
    fire_hook "$B" "/issue-create second turn" ISSUE_PROVENANCE=off >/dev/null
    [ -f "$(token_path "$B")" ] \
        && fail "T5b-off-revokes-existing-token" "a token survived a turn taken with ISSUE_PROVENANCE=off — the switch made the grant longer-lived, not shorter" \
        || pass "T5b-off-revokes-existing-token"
fi

echo ""
echo "=== T5c: with the switch off the CLI answers mid-workflow without reading disk ==="
# The reader side of the same switch. `off` must be decided before any marker is
# opened: a token, a consumption record and a decision record are all still on disk
# from the period when the switch was on, and none of them may be consulted, spent or
# rewritten. Observing that the consumption record is untouched is what distinguishes
# "answered mid-workflow" from "read everything, then discarded the answer".
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
if [ ! -f "$CLI" ]; then
    fail "T5c-off-answers-mid-workflow" "RED-EXPECTED: bin/github-issues/issue-provenance not found"
    fail "T5c-off-does-not-consume" "RED-EXPECTED: bin/github-issues/issue-provenance not found"
else
    B=$(new_env t5c)
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"/issue-create please"}}' > "$B/transcript.jsonl"
    printf '%s' "$(node_path "$B/transcript.jsonl")" > "$(transcript_ptr "$B")"
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  provenance:'user-explicit', target:'issue-create', match_layer:'slash', session_id:'$SID',
  minted_at:new Date().toISOString(),
  expires_at:new Date(Date.now()+15*60e3).toISOString()}), {mode:0o600});" \
        "$(node_path "$(token_path "$B")")" 2>/dev/null
    CONSUMED_F="$B/state/$SID.issue-provenance-consumed"
    V=$( cd "$B/cwd" && env ISSUE_PROVENANCE=off ISSUE_VERDICT_REVIEW=off \
        CLAUDE_WORKFLOW_DIR="$(node_path "$B/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$B/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" CLAUDE_CODE_SESSION_ID="$SID" \
        "$RWT" 20 bash "$CLI" --consume 2>/dev/null | head -n 1 | tr -d '[:space:]' )
    [ "$V" = "mid-workflow" ] && pass "T5c-off-answers-mid-workflow" \
        || fail "T5c-off-answers-mid-workflow" "want mid-workflow with the switch off, even over a valid token (got: '${V:-<none>}')"
    if [ -e "$CONSUMED_F" ] || [ -e "$B/state/$SID.issue-provenance-result" ]; then
        fail "T5c-off-does-not-consume" "the off path wrote a consumption or decision record — it must answer before touching disk"
    else
        pass "T5c-off-does-not-consume"
    fi
fi

echo ""
echo "=== T6: malformed payload → fail-open, stdout still {} ==="
if [ "$HOOK_PRESENT" != "yes" ]; then
    redh "T6-fail-open"
else
    B=$(new_env t6)
    OUT=$( cd "$B/cwd" && ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
             CLAUDE_WORKFLOW_DIR="$(node_path "$B/state")" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
             "$RWT" 15 node "$HOOK" <<< 'not json at all' 2>/dev/null )
    [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "{}" ] && pass "T6-fail-open" \
        || fail "T6-fail-open" "the hook must print {} on any exception (got: '$OUT')"
fi

echo ""
echo "=== T7: an expired token is not honoured by the consume CLI ==="
if [ "$CLI_PRESENT" != "yes" ]; then
    redc "T7-expired-token-mid-workflow"
else
    B=$(new_env t7)
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  provenance:'user-explicit', target:'issue-create', match_layer:'slash',
  minted_at: new Date(Date.now()-3600e3).toISOString(),
  expires_at: new Date(Date.now()-60e3).toISOString()}));" "$(node_path "$(token_path "$B")")" 2>/dev/null
    # Workflow state is active so layer C cannot rescue the expired token.
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({version:1,session_id:'$SID',created_at:new Date().toISOString(),
  steps:{research:{status:'complete'}}}));" "$(node_path "$B/state/$SID.json")" 2>/dev/null
    GOT=$( cd "$B/cwd" && ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
             CLAUDE_WORKFLOW_DIR="$(node_path "$B/state")" \
             WORKFLOW_PLANS_DIR="$(node_path "$B/plans")" \
             AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" CLAUDE_CODE_SESSION_ID="$SID" \
             "$RWT" 20 bash "$CLI" --consume 2>/dev/null | tr -d '[:space:]' )
    [ "$GOT" = "mid-workflow" ] && pass "T7-expired-token-mid-workflow" \
        || fail "T7-expired-token-mid-workflow" "an expired token must not yield user-explicit (got: '$GOT')"
fi

echo ""
echo "=== T8: session-markers.js exposes the provenance read/eval API ==="
SM="$AGENTS_DIR/hooks/lib/session-markers.js"
T=$("$RWT" 12 node -e "
try { const m = require(process.argv[1]);
  const need = ['readIssueProvenance','evaluateIssueProvenance','isIssueProvenanceValid'];
  const missing = need.filter(k => typeof m[k] !== 'function');
  process.stdout.write(missing.length ? 'missing:' + missing.join(',') : 'ok');
} catch (e) { process.stdout.write('err'); }" "$(node_path "$SM")" 2>/dev/null)
[ "$T" = "ok" ] && pass "T8-session-markers-api" \
    || fail "T8-session-markers-api" "RED-EXPECTED: session-markers.js lacks the provenance API ($T)"

echo ""
echo "=== T9: issue-provenance-keys.js is the single key-derivation source ==="
KEYS="$AGENTS_DIR/hooks/lib/issue-provenance-keys.js"
if [ ! -f "$KEYS" ]; then
    fail "T9-keys-module-api" "RED-EXPECTED: hooks/lib/issue-provenance-keys.js not yet created"
    fail "T9-paths-three-suffixes" "RED-EXPECTED: hooks/lib/issue-provenance-keys.js not yet created"
else
    T=$("$RWT" 12 node -e "
try { const m = require(process.argv[1]);
  process.stdout.write((typeof m.provenanceKeys==='function' && typeof m.provenancePaths==='function') ? 'ok' : 'missing');
} catch (e) { process.stdout.write('err'); }" "$(node_path "$KEYS")" 2>/dev/null)
    [ "$T" = "ok" ] && pass "T9-keys-module-api" || fail "T9-keys-module-api" "module must export provenanceKeys + provenancePaths (got: $T)"
    T=$(CLAUDE_WORKFLOW_DIR="$(node_path "$WORK")" "$RWT" 12 node -e "
try { const m = require(process.argv[1]); const p = m.provenancePaths('somekey');
  const ok = /\\.issue-provenance\$/.test(p.token) && /\\.issue-provenance-consumed\$/.test(p.consumed) && /\\.session-transcript\$/.test(p.transcript);
  process.stdout.write(ok ? 'ok' : 'bad:' + JSON.stringify(p));
} catch (e) { process.stdout.write('err'); }" "$(node_path "$KEYS")" 2>/dev/null)
    [ "$T" = "ok" ] && pass "T9-paths-three-suffixes" || fail "T9-paths-three-suffixes" "provenancePaths must return the 3 marker paths (got: $T)"
fi

echo ""
echo "=== T10: zombie-cleanup sweeps the three new marker suffixes ==="
ZC="$AGENTS_DIR/hooks/workflow-state/state-io/zombie-cleanup.js"
missing=""
for s in ".issue-provenance" ".issue-provenance-consumed" ".session-transcript"; do
    grep -qF "\"$s\"" "$ZC" || missing="${missing:+$missing }$s"
done
[ -z "$missing" ] && pass "T10-zombie-cleanup-suffixes" \
    || fail "T10-zombie-cleanup-suffixes" "RED-EXPECTED: zombie-cleanup.js does not sweep: $missing"

echo ""
echo "=== T11: cleanup is idempotent — a second sweep over already-removed markers ==="
# Cleanup runs on every session start, so it meets already-swept directories far more
# often than dirty ones. A second pass must be a silent no-op, not an error and not a
# second round of state churn.
if [ ! -f "$ZC" ]; then
    fail "T11-cleanup-first-pass-removes" "RED-EXPECTED: zombie-cleanup.js not found"
    fail "T11-cleanup-second-pass-noop"   "RED-EXPECTED: zombie-cleanup.js not found"
    fail "T11-cleanup-leaves-fresh-markers" "RED-EXPECTED: zombie-cleanup.js not found"
else
    ZDIR="$WORK/zombie"; mkdir -p "$ZDIR"
    OLD=$(node -e "process.stdout.write(String(Date.now()/1000 - 86400*30))")
    for s in issue-provenance issue-provenance-consumed session-transcript; do
        printf 'x' > "$ZDIR/stale-sid.$s"
        printf 'x' > "$ZDIR/fresh-sid.$s"
    done
    # Age only the stale set; the fresh set must survive both passes.
    ( cd "$ZDIR" && node -e "
const fs=require('fs'); const t=Number(process.argv[1]);
for (const f of fs.readdirSync('.')) if (f.startsWith('stale-')) fs.utimesSync(f, t, t);" "$OLD" )

    sweep() {
        CLAUDE_WORKFLOW_DIR="$(node_path "$ZDIR")" "$RWT" 20 node -e "
try { const m = require(process.argv[1]);
  const fn = m.cleanupZombies || m.default || m;
  if (typeof fn === 'function') fn();
  process.stdout.write('ran');
} catch (e) { process.stdout.write('err:' + e.message); }" "$(node_path "$ZC")" 2>/dev/null
    }

    R1=$(sweep)
    AFTER1=$(ls "$ZDIR" | wc -l | tr -d ' ')
    R2=$(sweep)
    AFTER2=$(ls "$ZDIR" | wc -l | tr -d ' ')

    if [ "$R1" = "ran" ] && [ "$AFTER1" -lt 6 ]; then
        pass "T11-cleanup-first-pass-removes"
    else
        fail "T11-cleanup-first-pass-removes" "RED-EXPECTED: the first sweep did not remove the aged markers (r=$R1, files left=$AFTER1)"
    fi
    if [ "$R2" = "ran" ] && [ "$AFTER2" = "$AFTER1" ]; then
        pass "T11-cleanup-second-pass-noop"
    else
        fail "T11-cleanup-second-pass-noop" "a repeat sweep must be a no-op (r=$R2, $AFTER1 → $AFTER2)"
    fi
    STILL=$(ls "$ZDIR" 2>/dev/null | grep -c '^fresh-sid\.' || printf 0)
    [ "$STILL" = "3" ] && pass "T11-cleanup-leaves-fresh-markers" \
        || fail "T11-cleanup-leaves-fresh-markers" "cleanup must not touch markers inside the retention window (3 → $STILL)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
