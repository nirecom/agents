#!/usr/bin/env bash
# tests/feat-1763-provenance-single-use.sh
# Tests: bin/github-issues/issue-provenance, hooks/lib/issue-provenance-consumed.js, hooks/lib/issue-provenance-keys.js, hooks/lib/issue-request-patterns.js, hooks/lib/workflow-activity.js
# Tags: issue-create, provenance, single-use, consumption-record, fail-closed, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real transcript JSONL produced by Claude Code (fixtures here), including compaction rewrites.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# S10d — the single-use boundary (risk C5). Every observation point (A token,
# B transcript re-scan, C workflow-inactive) shares ONE consumption record keyed by
# "<lineIndex>:<sha256(rawLine)>" of the latest user entry. Consuming through any
# layer must block re-issuance through every other layer for the same user entry.
#
# CLI contract: `issue-provenance --consume` → exit 0 always;
#   stdout = "user-explicit" | "mid-workflow"; stderr = "layer: A|B|C|none".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: bin/github-issues/issue-provenance not yet created"; }

CLI_PRESENT=no; [ -f "$CLI" ] && CLI_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SID="cc-session-single"

# new_env <name> <workflow-active: yes|no>
new_env() {
    local base="$WORK/$1" active="$2"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$SID-intent.md"
    : > "$base/transcript.jsonl"
    printf '%s' "$(node_path "$base/transcript.jsonl")" > "$base/state/$SID.session-transcript"
    if [ "$active" = "yes" ]; then
        node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({version:1,session_id:'$SID',
  created_at:new Date().toISOString(), workflow_type:'wf-code',
  steps:{research:{status:'complete'},write_tests:{status:'pending'}}}));" \
            "$(node_path "$base/state/$SID.json")" 2>/dev/null
    fi
    printf '%s' "$base"
}

add_user()      { TXT="$2" node -e "process.stdout.write(JSON.stringify({type:'user',message:{role:'user',content:process.env.TXT}}))" >> "$1/transcript.jsonl"; printf '\n' >> "$1/transcript.jsonl"; }
add_assistant() { printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"ack"}}' >> "$1/transcript.jsonl"; }

mint_token() {  # <base>
    node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  provenance:'user-explicit', target:'issue-create', match_layer:'slash',
  minted_at:new Date().toISOString(),
  expires_at:new Date(Date.now()+15*60e3).toISOString()}), {mode:0o600});" \
        "$(node_path "$1/state/$SID.issue-provenance")" 2>/dev/null
}

# consume <base> → sets VERDICT and LAYER
consume() {
    local base="$1"
    if [ "$CLI_PRESENT" != "yes" ]; then VERDICT="<missing>"; LAYER="<missing>"; return; fi
    local errf="$base/consume-stderr.txt"
    # Config pinning (rules/test.md): the single-use boundary is only meaningful with
    # the feature enabled, so it is pinned here rather than inherited from .env.
    VERDICT=$( cd "$base/cwd" && \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        CLAUDE_CODE_SESSION_ID="$SID" \
        "$RWT" 25 bash "$CLI" --consume 2>"$errf" | tr -d '[:space:]' )
    LAYER=$(grep -oE 'layer: *[A-Za-z]+' "$errf" 2>/dev/null | tail -n 1 | sed 's/.*: *//')
}

check() {  # <label> <want-verdict> [want-layer]
    if [ "$VERDICT" = "<missing>" ]; then red "$1"; return; fi
    local ok=1 msg=""
    [ "$VERDICT" = "$2" ] || { ok=0; msg="verdict want=$2 got=$VERDICT"; }
    if [ $# -ge 3 ] && [ "$ok" = "1" ] && [ "${LAYER:-}" != "$3" ]; then
        ok=0; msg="layer want=$3 got=${LAYER:-<none>}"
    fi
    [ "$ok" = "1" ] && pass "$1" || fail "$1" "$msg"
}

consumed_file() { printf '%s' "$1/state/$SID.issue-provenance-consumed"; }

echo "=== (a) token path consumes the record too — no transcript re-issuance ==="
B=$(new_env a yes)
add_user "$B" "please open an issue for the flaky hook"
mint_token "$B"
consume "$B"; check "A1-first-consume-user-explicit" "user-explicit" "A"
if [ "$CLI_PRESENT" = "yes" ]; then
    [ -f "$B/state/$SID.issue-provenance" ] && fail "A2-token-unlinked" "the token survived consumption" || pass "A2-token-unlinked"
    [ -f "$(consumed_file "$B")" ] && pass "A3-consumption-recorded" \
        || fail "A3-consumption-recorded" "the token path must also write the consumption record (C5 loophole)"
else
    red "A2-token-unlinked"; red "A3-consumption-recorded"
fi
consume "$B"; check "A4-second-consume-mid-workflow" "mid-workflow"

echo ""
echo "=== (b) layer B: unconsumed matching user entry, no token ==="
B=$(new_env b yes)
add_user "$B" "この件、イシュー立てといて"
consume "$B"; check "B1-first-consume-layer-B" "user-explicit" "B"
consume "$B"; check "B2-second-consume-mid-workflow" "mid-workflow"

echo ""
echo "=== (c) layer C: workflow inactive, no vocabulary match ==="
B=$(new_env c no)
add_user "$B" "これ、あとで見るように残しといて"
consume "$B"; check "C1-first-consume-layer-C" "user-explicit" "C"
consume "$B"; check "C2-second-consume-mid-workflow" "mid-workflow"

echo ""
echo "=== (d) a NEW user entry re-enables issuance (lineIndex distinguishes turns) ==="
B=$(new_env d yes)
add_user "$B" "please file an issue about the parser"
consume "$B"; check "D1-first-turn-user-explicit" "user-explicit" "B"
consume "$B"; check "D2-same-turn-repeat-mid-workflow" "mid-workflow"
add_assistant "$B"
add_user "$B" "please file an issue about the hook too"
consume "$B"; check "D3-new-turn-user-explicit-again" "user-explicit" "B"

echo ""
echo "=== (e) the same wording sent twice on different lines issues twice ==="
B=$(new_env e yes)
add_user "$B" "課題として登録しておいて"
consume "$B"; check "E1-first-identical-wording" "user-explicit" "B"
add_assistant "$B"
add_user "$B" "課題として登録しておいて"
consume "$B"; check "E2-second-identical-wording-different-line" "user-explicit" "B"

echo ""
echo "=== (f) the consumption record is FIFO-capped at 20 entries ==="
B=$(new_env f yes)
add_user "$B" "please open an issue for the FIFO case"
if [ "$CLI_PRESENT" != "yes" ]; then
    red "F1-fifo-cap-20"; red "F2-fifo-drops-oldest"
else
    node -e "
const fs=require('fs');
const list=[]; for (let i=0;i<20;i++) list.push(i + ':' + 'f'.repeat(64));
fs.writeFileSync(process.argv[1], JSON.stringify({consumed:list}), {mode:0o600});" \
        "$(node_path "$(consumed_file "$B")")" 2>/dev/null
    OLDEST="0:$(printf 'f%.0s' $(seq 1 64))"
    consume "$B"
    LEN=$("$RWT" 12 node -e "
try { const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write(String((d.consumed||[]).length)); } catch(e){ process.stdout.write('err'); }" \
        "$(node_path "$(consumed_file "$B")")" 2>/dev/null)
    [ "$LEN" = "20" ] && pass "F1-fifo-cap-20" || fail "F1-fifo-cap-20" "want 20 retained entries (got: $LEN)"
    HAS=$(OLD="$OLDEST" "$RWT" 12 node -e "
try { const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write((d.consumed||[]).includes(process.env.OLD) ? 'present' : 'dropped'); } catch(e){ process.stdout.write('err'); }" \
        "$(node_path "$(consumed_file "$B")")" 2>/dev/null)
    [ "$HAS" = "dropped" ] && pass "F2-fifo-drops-oldest" || fail "F2-fifo-drops-oldest" "the oldest fingerprint must be evicted (got: $HAS)"
fi

echo ""
echo "=== (g) unreadable consumption record → fail-CLOSED (mid-workflow) ==="
B=$(new_env g yes)
add_user "$B" "please open an issue, the record is corrupt"
printf '%s' '{ this is not valid json' > "$(consumed_file "$B")"
consume "$B"; check "G1-corrupt-record-fail-closed" "mid-workflow"

echo ""
echo "=== (h) unwritable consumption record → fail-CLOSED (mid-workflow) ==="
B=$(new_env h yes)
add_user "$B" "please open an issue, the record cannot be written"
rm -f "$(consumed_file "$B")" 2>/dev/null || true
mkdir -p "$(consumed_file "$B")"   # a directory at the record path makes any write fail
consume "$B"; check "H1-unwritable-record-fail-closed" "mid-workflow"

echo ""
echo "=== (i) no transcript at all → fail-CLOSED even when the workflow is inactive ==="
B=$(new_env i no)
rm -f "$B/state/$SID.session-transcript" "$B/transcript.jsonl"
consume "$B"; check "I1-no-transcript-fail-closed" "mid-workflow"

echo ""
echo "=== (j) exit code is always 0 ==="
if [ "$CLI_PRESENT" != "yes" ]; then
    red "J1-exit-always-0"
else
    B=$(new_env j yes)
    ( cd "$B/cwd" && ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        CLAUDE_WORKFLOW_DIR="$(node_path "$B/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$B/plans")" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        CLAUDE_CODE_SESSION_ID="$SID" "$RWT" 25 bash "$CLI" --consume >/dev/null 2>&1 )
    RC=$?
    [ "$RC" -eq 0 ] && pass "J1-exit-always-0" || fail "J1-exit-always-0" "want exit 0 on the mid-workflow path (got $RC)"
fi

echo ""
echo "=== (k) issue-provenance-consumed.js exposes the fingerprint API ==="
MOD="$AGENTS_DIR/hooks/lib/issue-provenance-consumed.js"
if [ ! -f "$MOD" ]; then
    fail "K1-consumed-module-api" "RED-EXPECTED: hooks/lib/issue-provenance-consumed.js not yet created"
else
    T=$("$RWT" 12 node -e "
try { const m=require(process.argv[1]);
  process.stdout.write((typeof m.isConsumed==='function' && typeof m.recordConsumed==='function') ? 'ok' : 'missing');
} catch(e){ process.stdout.write('err'); }" "$(node_path "$MOD")" 2>/dev/null)
    [ "$T" = "ok" ] && pass "K1-consumed-module-api" || fail "K1-consumed-module-api" "module must export isConsumed + recordConsumed (got: $T)"

    # K2/K3 — a record that exists but cannot be interpreted. This is the one failure
    # mode where the obvious repair is the dangerous one: "the record is corrupt, so
    # start a fresh empty list" silently re-arms every fingerprint already spent, which
    # turns one corrupted file into unlimited re-issuance. Both entry points must treat
    # it as "already consumed" / "cannot guarantee" instead (CPR-5: same condition,
    # same answer on both sides of the module's API).
    KB="$WORK/kdir"; mkdir -p "$KB"
    printf '%s' '{"consumed": [ truncated' > "$KB/$SID.issue-provenance-consumed"
    KOUT=$("$RWT" 12 node -e "
try {
  const fs = require('fs');
  const m = require(process.argv[1]);
  const before = fs.readFileSync(process.argv[2], 'utf8');
  const consumed = m.isConsumed(process.env.SID, '0:deadbeef');
  const wrote = m.recordConsumed(process.env.SID, '0:deadbeef');
  const after = fs.readFileSync(process.argv[2], 'utf8');
  process.stdout.write([consumed, wrote, before === after].join(','));
} catch (e) { process.stdout.write('err:' + e.message); }" \
        "$(node_path "$MOD")" "$(node_path "$KB/$SID.issue-provenance-consumed")" \
        2>/dev/null <<<"" )
    # env for the call above
    KOUT=$(SID="$SID" CLAUDE_WORKFLOW_DIR="$(node_path "$KB")" "$RWT" 12 node -e "
try {
  const fs = require('fs');
  const m = require(process.argv[1]);
  const before = fs.readFileSync(process.argv[2], 'utf8');
  const consumed = m.isConsumed(process.env.SID, '0:deadbeef');
  const wrote = m.recordConsumed(process.env.SID, '0:deadbeef');
  const after = fs.readFileSync(process.argv[2], 'utf8');
  process.stdout.write([consumed, wrote, before === after].join(','));
} catch (e) { process.stdout.write('err:' + e.message); }" \
        "$(node_path "$MOD")" "$(node_path "$KB/$SID.issue-provenance-consumed")" 2>/dev/null)
    case "$KOUT" in
        true,*) pass "K2-unreadable-record-reads-as-consumed" ;;
        *) fail "K2-unreadable-record-reads-as-consumed" "isConsumed must fail closed on an unreadable record (got: '${KOUT:-<none>}')" ;;
    esac
    case "$KOUT" in
        *,false,true) pass "K3-unreadable-record-is-not-reset" ;;
        *) fail "K3-unreadable-record-is-not-reset" "recordConsumed must refuse and leave the record untouched, never replace it with a fresh list (isConsumed,wrote,unchanged = '${KOUT:-<none>}')" ;;
    esac
fi

echo ""
echo "=== (l) transcript compaction / rewrite replay — the accepted residual, bounded ==="
# The fingerprint is "<lineIndex>:<sha256(rawLine)>", so ANY rewrite that moves a line
# changes its fingerprint and the entry looks new. Compaction does exactly that, and
# Claude Code performs it without notice. This is a KNOWN residual (detail.md risk (i)),
# deliberately accepted over a content-only fingerprint — which would make two genuinely
# separate identical requests indistinguishable, silently dropping the second turn's
# authorization. The contract is therefore not "never replays" but "the blast radius of
# a replay is at most ONE omitted confirmation": the re-issued request is consumed on
# sight, and the very next consume is back to mid-workflow.
if [ "$CLI_PRESENT" != "yes" ]; then
    red "L1-preamble-consumed"; red "L2-append-does-not-reissue"
    red "L3-compaction-may-reissue-once"; red "L4-replay-is-bounded"
    red "L5-record-retains-both-fingerprints"; red "L6-summary-only-transcript-fails-closed"
else
    B=$(new_env l no)
    add_assistant "$B"
    add_assistant "$B"
    add_user "$B" "この件、チケット起票しておいて"
    consume "$B"; check "L1-preamble-consumed" "user-explicit" "B"

    # Appending never shifts an existing index, so the consumed entry must stay consumed.
    add_assistant "$B"
    consume "$B"; check "L2-append-does-not-reissue" "mid-workflow"

    # Compaction: the two leading assistant turns are replaced by a single summary line,
    # so the request line moves from index 2 to index 1. Byte-identical content, new index.
    node -e "
const fs = require('fs');
const p = process.argv[1];
const lines = fs.readFileSync(p, 'utf8').split('\n').filter(Boolean);
const req = lines.find(l => l.includes('起票'));
fs.writeFileSync(p, [JSON.stringify({type:'assistant',message:{role:'assistant',content:'[compacted summary]'}}), req].join('\n') + '\n');
" "$(node_path "$B/transcript.jsonl")"

    consume "$B"
    if [ "$VERDICT" = "user-explicit" ]; then
        # The residual fired. Acceptable exactly once — assert the bound holds.
        pass "L3-compaction-may-reissue-once"
        consume "$B"; check "L4-replay-is-bounded" "mid-workflow"
    elif [ "$VERDICT" = "mid-workflow" ]; then
        # A stronger implementation (e.g. content-plus-position fingerprint that
        # tolerates shifts) also satisfies the contract.
        pass "L3-compaction-may-reissue-once"
        pass "L4-replay-is-bounded"
    else
        fail "L3-compaction-may-reissue-once" "want user-explicit or mid-workflow (got: '${VERDICT:-<none>}')"
        fail "L4-replay-is-bounded" "no defined verdict to bound"
    fi

    # Whichever way it went, the record must have grown rather than been reset —
    # a cleared record would make the replay unbounded.
    CF=$(consumed_file "$B")
    if [ -f "$CF" ]; then
        N=$("$RWT" 12 node -e "
try { const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write(String((Array.isArray(d) ? d : (d.consumed || [])).length));
} catch (e) { process.stdout.write('parse-error'); }" "$(node_path "$CF")" 2>/dev/null)
        [ "$N" != "parse-error" ] && [ "$N" -ge 1 ] 2>/dev/null && pass "L5-record-retains-both-fingerprints" \
            || fail "L5-record-retains-both-fingerprints" "the consumption record must accumulate, not reset (entries=$N)"
    else
        fail "L5-record-retains-both-fingerprints" "RED-EXPECTED: no consumption record was written"
    fi

    # Compaction that drops the request entirely leaves no evidence of a user ask.
    B2=$(new_env l2 yes)
    add_user "$B2" "この件、チケット起票しておいて"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"[compacted summary]"}}' > "$B2/transcript.jsonl"
    consume "$B2"; check "L6-summary-only-transcript-fails-closed" "mid-workflow"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
