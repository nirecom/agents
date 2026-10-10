#!/usr/bin/env bash
# tests/bin/fix-1780-round12-mint-claim-idempotency.sh
# Tests: bin/request-off-clearance, hooks/lib/consume-exact-file.js
# Tags: off-clearance, mint, claim, mint-nonce, idempotency, replay, single-use, concurrency, race, filesystem, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: the REAL claimant (R1's racer is a node poller that COPIES the token into .claimed, not the shim hook in a live claude -p turn); a real mid-syscall crash between the mint's rename and its sweep (M6 makes the destination unwritable instead); real 0600 on .claimed (Git Bash emulates).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
# WHAT THIS FILE DEFENDS (#1626 + #1780 M-3 / round-5 M-2): `.claimed` makes a grant SINGLE-USE, so the mint's clear step is IDENTITY-BOUND, not an `rm -f`.
# Clearing too little deadlocks the sid until the 7-day zombie sweep; clearing too much erases the single-use record of a LIVE grant.
# INVARIANT every case checks: a claim is removed iff its CONTENTS prove it belongs to a DIFFERENT grant (different mint_nonce, or none at all).
# ORDER (M6): the claim is cleared only AFTER the new bare token is durably minted. REPLAY (M7): re-minting never resurrects a spent grant.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./lib/request-off-clearance-harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/request-off-clearance-harness.sh"
# shellcheck source=../lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

offclr_require_script

SID="mintclaim"

# write_claim <tmp_node> <raw-json-or-literal> — plant a pre-existing .claimed.
write_claim() {
    "$OFFCLR_RWT" 15 node -e '
const fs = require("fs"), path = require("path");
fs.writeFileSync(path.join(process.argv[1], process.argv[2] + ".off-clearance.claimed"),
                 process.argv[3], { mode: 0o600 });
' "$1" "$SID" "$2" >/dev/null 2>&1
}

claim_file() { printf '%s/%s.off-clearance.claimed' "$1" "$SID"; }
token_file() { printf '%s/%s.off-clearance' "$1" "$SID"; }

# a claim body carrying an explicit mint_nonce (or none, when $2 is empty)
claim_body() {
    "$OFFCLR_RWT" 15 node -e '
const o = { target:"workflow", category:"workflow-bug", urgency:"normal",
  minted_at:new Date().toISOString(), expires_at:new Date(Date.now()+9e5).toISOString(),
  verdict_reason:"examiner ALLOW", detail:"prior grant",
  claimed_at:new Date().toISOString(), claimed_reason:"[workflow-bug] a previous proposal" };
if (process.argv[1]) o.mint_nonce = process.argv[1];
process.stdout.write(JSON.stringify(o));
' "${1:-}" 2>/dev/null
}

# ===========================================================================
# M1 - THE CLEAR RULE, table-driven over what can be sitting at the claim path.
# One row per class of prior claim; all four are "cannot prove it belongs to
# this grant", so all four must be swept, and the fresh token must be minted in
# every case. Rows share one assertion block so a new claim shape is one row.
# ===========================================================================
run_M1() {
    local rows row label body tmp tn ok
    # Bodies are produced by name so the table stays readable.
    rows='different mint_nonce (an older grant)|other
no mint_nonce at all (pre-#1780 claim)|none
unparseable bytes|garbage
valid JSON but an ARRAY|array
valid JSON null|null
empty file|empty'
    while IFS='|' read -r label row; do
        [ -n "$label" ] || continue
        case "$row" in
            other)   body="$(claim_body 'ffffffffffffffffffffffffffffffff')" ;;
            none)    body="$(claim_body '')" ;;
            garbage) body='not json at all {{{' ;;
            array)   body='[{"mint_nonce":"ffffffffffffffffffffffffffffffff"}]' ;;
            null)    body='null' ;;
            empty)   body='' ;;
        esac
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        write_claim "$tn" "$body"
        REQ_SID="$SID"
        run_req "$tn" "$(allow_stub 'fresh examination')" --target workflow --category workflow-bug --detail "bug"
        ok=1
        [ "$RC" -eq 0 ] || ok=0
        [ -f "$(token_file "$tmp")" ] || ok=0
        [ ! -f "$(claim_file "$tmp")" ] || ok=0
        # the identity-bound sweep must not leave its own exclusive-window file behind
        [ "$(tmpres_count "$tmp")" -eq 0 ] || ok=0
        if [ "$ok" = "1" ]; then
            pass "M1 [$label] -> swept by the fresh grant, new bare token minted, no .consuming-*/.mint.tmp residue"
        else
            fail "M1 [$label] -> rc=$RC token=$([ -f "$(token_file "$tmp")" ] && echo yes || echo NO) claim_left=$([ -f "$(claim_file "$tmp")" ] && echo YES || echo no) residue=$(tmpres_count "$tmp") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done <<< "$rows"
}

# ===========================================================================
# M2 - NO PRIOR CLAIM. The clear step must be a pure no-op: minting must never
# CREATE a .claimed file (that would spend the grant at birth).
# ===========================================================================
run_M2() {
    local tmp tn ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    [ "$RC" -eq 0 ] || ok=0
    [ -f "$(token_file "$tmp")" ] || ok=0
    [ "$(claim_count "$tmp")" -eq 0 ] || ok=0
    [ "$(tmpres_count "$tmp")" -eq 0 ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "M2 no prior claim -> mint is a pure write: bare token only, NO .claimed created"
    else
        fail "M2 rc=$RC tokens=$(token_count "$tmp") claims=$(claim_count "$tmp") residue=$(tmpres_count "$tmp")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# M3 - AN UNREADABLE CLAIM IS LEFT ALONE. A read error that is not ENOENT gives
# no evidence either way, so the mint must not guess: it leaves the pathname
# untouched and still mints. Simulated with a DIRECTORY at the claim path, the
# one unreadable shape that is portable across POSIX and Windows.
# ===========================================================================
run_M3() {
    local tmp tn ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    mkdir -p "$(claim_file "$tmp")"
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub)" --target workflow --category workflow-bug --detail "bug"
    [ "$RC" -eq 0 ] || ok=0
    [ -f "$(token_file "$tmp")" ] || ok=0
    [ -d "$(claim_file "$tmp")" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "M3 unreadable (non-ENOENT) claim path -> left untouched, mint still succeeds"
    else
        fail "M3 rc=$RC token=$([ -f "$(token_file "$tmp")" ] && echo yes || echo NO) dir_left=$([ -d "$(claim_file "$tmp")" ] && echo yes || echo NO) err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# M4 - A REJECTED EXAMINATION CLEARS NOTHING. Only a fresh, examiner-APPROVED
# grant may supersede a claim; if a REJECT swept it, any caller could clear
# another proposal's single-use lock just by asking and being refused.
# ===========================================================================
run_M4() {
    local tmp tn body before ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body="$(claim_body 'ffffffffffffffffffffffffffffffff')"
    write_claim "$tn" "$body"
    before="$(cat "$(claim_file "$tmp")")"
    REQ_SID="$SID"
    run_req "$tn" "$(reject_stub 'no legitimate need')" --target workflow --category workflow-bug --detail "bug"
    [ "$RC" -ne 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    [ -f "$(claim_file "$tmp")" ] || ok=0
    [ "$(cat "$(claim_file "$tmp")" 2>/dev/null)" = "$before" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "M4 REJECT clears nothing: the prior claim survives byte-identical, NO token minted"
    else
        fail "M4 RED-EXPECTED: a refused examination touched another grant's claim; rc=$RC claim_left=$([ -f "$(claim_file "$tmp")" ] && echo yes || echo NO)"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# M5 - REPEAT MINTING IS IDEMPOTENT IN SHAPE, FRESH IN IDENTITY. Two ALLOWs back
# to back leave exactly ONE bare token, no staging residue, and a DIFFERENT
# mint_nonce — the second grant must not be able to pass as the first.
# ===========================================================================
run_M5() {
    local tmp tn n1 n2 ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub 'first')" --target workflow --category workflow-bug --detail "bug"
    n1="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub 'second')" --target workflow --category workflow-bug --detail "bug"
    n2="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
    [ "$(token_count "$tmp")" -eq 1 ] || ok=0
    [ "$(tmpres_count "$tmp")" -eq 0 ] || ok=0
    [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" != "$n2" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "M5 two consecutive mints -> exactly one bare token, fresh mint_nonce, no residue"
    else
        fail "M5 tokens=$(token_count "$tmp") residue=$(tmpres_count "$tmp") n1=$n1 n2=$n2"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# M6 - ORDER: MINT FIRST, CLEAR SECOND (codex round-4 HIGH).
#
# If the clear ran first, a mint that then FAILED would leave the OLD bare token
# in place with its single-use lock removed — an already-spent grant, replayable
# for the rest of its 15-minute window. The mint is forced to fail by putting a
# DIRECTORY where the bare token must land (the rename cannot overwrite it); the
# prior claim must survive.
# ===========================================================================
run_M6() {
    local tmp tn before ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claim "$tn" "$(claim_body 'ffffffffffffffffffffffffffffffff')"
    before="$(cat "$(claim_file "$tmp")")"
    mkdir -p "$(token_file "$tmp")"
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub 'approved but unmintable')" --target workflow --category workflow-bug --detail "bug"
    [ "$RC" -ne 0 ] || ok=0
    ! echo "$OUT" | grep -q "Clearance token minted" || ok=0
    [ -f "$(claim_file "$tmp")" ] || ok=0
    [ "$(cat "$(claim_file "$tmp")" 2>/dev/null)" = "$before" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "M6 mint FAILS -> the prior claim survives intact (a spent grant is never re-armed by a failed mint)"
    else
        fail "M6 RED-EXPECTED (clear-before-mint ordering): rc=$RC claim_left=$([ -f "$(claim_file "$tmp")" ] && echo yes || echo NO) out=$(printf '%q' "$OUT")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# M7 - NO REPLAY OF A SPENT GRANT. Full lifecycle: mint -> the shim claims it
# (bare consumed into .claimed) -> re-mint. The spent grant's claim is swept
# because it belongs to the OLD identity, and what replaces it is a NEW identity
# — the old token's bytes exist nowhere on disk afterwards, so nothing that
# recorded the first grant can be presented again.
# ===========================================================================
run_M7() {
    local tmp tn old_raw old_nonce new_nonce ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub 'first grant')" --target workflow --category workflow-bug --detail "bug"
    old_raw="$(cat "$(token_file "$tmp")" 2>/dev/null)"
    old_nonce="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
    # simulate the shim's claim: the bare token becomes the .claimed record
    mv "$(token_file "$tmp")" "$(claim_file "$tmp")"

    REQ_SID="$SID"
    run_req "$tn" "$(allow_stub 'second grant')" --target workflow --category workflow-bug --detail "bug"
    new_nonce="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
    [ "$RC" -eq 0 ] || ok=0
    [ "$(token_count "$tmp")" -eq 1 ] || ok=0
    [ "$(claim_count "$tmp")" -eq 0 ] || ok=0
    [ -n "$new_nonce" ] && [ "$new_nonce" != "$old_nonce" ] || ok=0
    # the spent grant's exact bytes must not survive anywhere under the dir
    ! grep -rqF "$old_raw" "$tmp" 2>/dev/null || ok=0
    if [ "$ok" = "1" ]; then
        pass "M7 spent grant -> re-mint sweeps its claim and issues a NEW identity; the old grant's bytes are gone (no replay)"
    else
        fail "M7 rc=$RC tokens=$(token_count "$tmp") claims=$(claim_count "$tmp") old=$old_nonce new=$new_nonce"
    fi
    rm -r -f "$tmp" 2>/dev/null || true
}

# ===========================================================================
# THE RACE (#1780 M-3). A claim written for the token minted microseconds earlier must
# SURVIVE the same mint's clear step. The window is inside ONE node process, between
# fs.renameSync(p + ".mint.tmp", p) and fs.readFileSync(p + ".claimed"); a claimant that
# writes AFTER the read is not in the race, so a natural-timing poller proves nothing
# (validated by mutation: R1 fails against an `rm -f` mint, R2 does not). R1 therefore
# WIDENS the window instead of racing for it: only
# require(SCRIPT_CHECKOUT_ROOT + "/hooks/lib/consume-exact-file.js") sits in it. R2 keeps
# the natural-timing poller as an unwidened probe. The poller COPIES the bare token into
# .claimed, so the grant's identity stays readable; the sweep reads only the CLAIM.

offclr_fake_checkout_stall() {
    # <dir> <delay-ms> — the mint derives its root from its own path, so the stall is
    # planted in a fake script checkout (a copy of bin hooks skills) the mint is launched
    # from. Only the DURATION of the window changes: the module re-exports the REAL one.
    local dir="$1" delay="$2" real
    real="$(node_path "$SCRIPT_CHECKOUT_ROOT")"
    script_checkout_fixture_copy "$dir" || return 1
    {
        printf '// TEST SHADOW: stalls %sms at load to widen the mint window, then\n' "$delay"
        printf '// re-exports the REAL primitive unchanged.\n'
        printf 'const end = Date.now() + %s;\n' "$delay"
        printf 'while (Date.now() < end) { /* block */ }\n'
        printf 'module.exports = require(%s);\n' "\"$real/hooks/lib/consume-exact-file.js\""
    } > "$dir/hooks/lib/consume-exact-file.js"
}

run_R1() {
    local racer fake_script_checkout_root tmp tn nf nw log ok=1 saved_req="$OFFCLR_REQ"
    racer="$(make_tmp)/racer.js"
    fake_script_checkout_root="$(make_tmp)/stall-checkout"
    offclr_fake_checkout_stall "$fake_script_checkout_root" 400
    cat > "$racer" <<'RACER'
"use strict";
const fs = require("fs");
const tokenPath = process.argv[2];
const logPath = process.argv[3];
const deadline = Date.now() + 30000;
function log(v) { try { fs.writeFileSync(logPath, String(v)); } catch (e) {} }
while (Date.now() < deadline) {
  let raw = null;
  try { raw = fs.readFileSync(tokenPath, "utf8"); } catch (e) { continue; }
  let t = null;
  try { t = JSON.parse(raw); } catch (e) { continue; }
  if (!t || !t.mint_nonce) continue;
  const claim = JSON.stringify(Object.assign({}, t, {
    claimed_at: new Date().toISOString(),
    claimed_target: "workflow",
    claimed_reason: "[workflow-bug] concurrent proposal",
  }));
  try {
    const fd = fs.openSync(tokenPath + ".claimed", "wx", 0o600);
    fs.writeSync(fd, claim);
    fs.closeSync(fd);
    log(t.mint_nonce);
  } catch (e) {
    log("CLAIMFAIL:" + (e && e.code));
  }
  process.exit(0);
}
log("NOTSEEN");
RACER

    tmp=$(make_tmp); tn=$(node_path "$tmp")
    log="$tmp/racer.log"
    node "$racer" "$(node_path "$(token_file "$tmp")")" "$(node_path "$log")" >/dev/null 2>&1 &
    local racer_pid=$!
    REQ_SID="$SID"; OFFCLR_REQ="$fake_script_checkout_root/bin/request-off-clearance"
    run_req "$tn" "$(allow_stub 'raced grant')" --target workflow --category workflow-bug --detail "bug"
    OFFCLR_REQ="$saved_req"
    wait "$racer_pid" 2>/dev/null || true

    nw="$(cat "$log" 2>/dev/null | tr -d '\r\n')"
    nf="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
    [ "$RC" -eq 0 ] || ok=0
    [ -n "$nf" ] && [ "$nw" = "$nf" ] || ok=0            # the claimant really claimed THIS grant
    [ -f "$(claim_file "$tmp")" ] || ok=0                # ...and its claim survived
    [ "$(offclr_json "$(claim_file "$tmp")" 't.mint_nonce')" = "$nf" ] || ok=0
    [ "$(tmpres_count "$tmp")" -eq 0 ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "R1 a claim written INSIDE the mint window, carrying this grant's mint_nonce, survives the same mint's sweep"
    else
        fail "R1 RED-EXPECTED (#1780 M-3 unconditional rm -f): rc=$RC claimant_wrote=$nw grant=$nf claim_left=$([ -f "$(claim_file "$tmp")" ] && echo yes || echo NO) residue=$(tmpres_count "$tmp")"
    fi
    rm -r -f "$tmp" "$(dirname "$racer")" "$(dirname "$fake_script_checkout_root")" 2>/dev/null || true
}

# R2 - the same scenario at NATURAL timing, as an unwidened probe. It reports
# whether the claimant ever reached the un-widened window on this machine; it
# cannot prove the rule (see the block above), so it never fails on a miss.
run_R2() {
    local racer tmp tn i landed=0 broken=0 nf nw log
    racer="$(make_tmp)/racer.js"
    cat > "$racer" <<'RACER'
"use strict";
const fs = require("fs");
const tokenPath = process.argv[2];
const logPath = process.argv[3];
const deadline = Date.now() + 30000;
function log(v) { try { fs.writeFileSync(logPath, String(v)); } catch (e) {} }
while (Date.now() < deadline) {
  let raw = null;
  try { raw = fs.readFileSync(tokenPath, "utf8"); } catch (e) { continue; }
  let t = null;
  try { t = JSON.parse(raw); } catch (e) { continue; }
  if (!t || !t.mint_nonce) continue;
  const claim = JSON.stringify(Object.assign({}, t, {
    claimed_at: new Date().toISOString(),
    claimed_target: "workflow",
    claimed_reason: "[workflow-bug] concurrent proposal",
  }));
  try {
    const fd = fs.openSync(tokenPath + ".claimed", "wx", 0o600);
    fs.writeSync(fd, claim);
    fs.closeSync(fd);
    log(t.mint_nonce);
  } catch (e) {
    log("CLAIMFAIL:" + (e && e.code));
  }
  process.exit(0);
}
log("NOTSEEN");
RACER

    for i in 1 2 3; do
        tmp=$(make_tmp); tn=$(node_path "$tmp")
        log="$tmp/racer.log"
        node "$racer" "$(node_path "$(token_file "$tmp")")" "$(node_path "$log")" >/dev/null 2>&1 &
        local racer_pid=$!
        REQ_SID="$SID"
        run_req "$tn" "$(allow_stub 'raced grant')" --target workflow --category workflow-bug --detail "bug"
        wait "$racer_pid" 2>/dev/null || true

        nw="$(cat "$log" 2>/dev/null | tr -d '\r\n')"
        nf="$(offclr_json "$(token_file "$tmp")" 't.mint_nonce')"
        if [ -n "$nw" ] && [ "$nw" = "$nf" ]; then
            landed=$((landed + 1))
            if [ ! -f "$(claim_file "$tmp")" ]; then
                broken=$((broken + 1))
            elif [ "$(offclr_json "$(claim_file "$tmp")" 't.mint_nonce')" != "$nf" ]; then
                broken=$((broken + 1))
            fi
        fi
        rm -r -f "$tmp" 2>/dev/null || true
    done
    rm -r -f "$(dirname "$racer")" 2>/dev/null || true

    if [ "$landed" -eq 0 ]; then
        skip "R2 the concurrent claimant never landed inside the un-widened mint window in 3 attempts - natural-timing probe only (not a pass)"
    elif [ "$broken" -eq 0 ]; then
        pass "R2 a claim carrying THIS grant's mint_nonce survived the same mint's sweep in all $landed/3 naturally-timed iterations"
    else
        fail "R2 RED-EXPECTED (#1780 M-3 unconditional rm -f): the mint destroyed a live claim for the grant it had just minted in $broken/$landed naturally-timed iterations"
    fi
}

run_M1
run_M2
run_M3
run_M4
run_M5
run_M6
run_M7
run_R1
run_R2

offclr_report
