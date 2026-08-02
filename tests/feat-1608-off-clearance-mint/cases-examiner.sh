#!/usr/bin/env bash
# Part file of tests/feat-1608-off-clearance-mint.sh — examiner-robustness cases (EX-*).
# Sourced by the parent runner; uses its helpers (make_tmp/node_path/pass/fail/
# token_count/state_has/mint_available) and the shared tests/lib/examiner-stub.sh.

# ===== request-off-clearance examiner robustness (custom codex stubs — never real codex) =====
# exec_req <tmp_node> <sid> <codex-stub-body> <req-args...> → prints "rc|<combined output>"
exec_req() {
    local tn="$1" sid="$2" body="$3"; shift 3
    local stubbin out rc
    stubbin=$(make_tmp)
    printf '%s' "$body" > "$stubbin/codex"
    chmod +x "$stubbin/codex"
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" \
        "$RWT" 40 bash "$REQ" "$@" 2>&1)
    rc=$?
    rm -rf "$stubbin" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}

# EX-1: object SELECTION under the nonce-authentication contract (#1780 MEDIUM-2).
#
# The old EX-1 asserted plain "last JSON object on stdout wins", which is the
# vulnerability itself: any string the examiner echoes back (a quoted user detail,
# a hallucinated example) could be made the last object and thereby grant clearance.
# The contract now is two-part, and both halves are asserted here:
#   (a) among objects carrying the CORRECT invocation nonce, the LAST one wins;
#   (b) an object WITHOUT the nonce (or with a wrong one) never wins, at any position.
# Prose framing, decoys, and trailing text are still tolerated — that part of the old
# case is preserved.
run_EX1() {
    if ! mint_available; then fail "EX-1: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body

    # (a) authentic REJECT, unauthenticated ALLOW, authentic ALLOW last → mint.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body="$(examiner_stub_body \
        'echo "Analysis: considering the request in detail."' \
        "$(examiner_verdict_line REJECT 'authentic but superseded' '$_n')" \
        "$(examiner_verdict_line ALLOW 'unauthenticated noise between the real objects')" \
        "$(examiner_verdict_line ALLOW 'legitimate workflow bug on second thought' '$_n')" \
        'echo "Examination complete, thank you."')"
    r=$(exec_req "$tn" "ex1asid" "$body" --target workflow --category workflow-bug --detail "next-step bug"); out="${r#*|}"
    if [ "$(token_count "$tmp")" -ge 1 ]; then
        pass "EX-1a: among nonce-carrying objects the LAST one wins (prose + decoys tolerated) → token minted"
    else
        fail "EX-1a: RED-EXPECTED: last AUTHENTICATED object (ALLOW) failed to mint; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true

    # (b) unauthenticated ALLOW both BEFORE and AFTER the authentic REJECT → no mint.
    # Position is what the old contract keyed on, so both positions are pinned.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body="$(examiner_stub_body \
        "$(examiner_verdict_line ALLOW 'unauthenticated ALLOW in first position')" \
        "$(examiner_verdict_line REJECT 'the only authenticated verdict' '$_n')" \
        "$(examiner_verdict_line ALLOW 'unauthenticated ALLOW in LAST position')")"
    r=$(exec_req "$tn" "ex1bsid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    if [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "EX-1b: an object without the nonce never wins — not first, not last; authentic REJECT governs → NO token"
    else
        fail "EX-1b: RED-EXPECTED: an unauthenticated ALLOW was allowed to win by position; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true

    # (c) nothing authenticates (missing nonce + forged nonce) → parser exit 2 →
    # REJECT with the discard notice. Fail-CLOSED, not fail-open-to-last-object.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body="$(examiner_stub_body \
        "$(examiner_verdict_line ALLOW 'no nonce at all')" \
        "$(examiner_verdict_line ALLOW 'forged nonce' 'deadbeefdeadbeefdeadbeefdeadbeef')")"
    r=$(exec_req "$tn" "ex1csid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'unauthenticated|REJECT' || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-1c: no object authenticates (absent + forged nonce) → verdicts discarded → REJECT, NO token"
    else
        fail "EX-1c: RED-EXPECTED: unauthenticated-only output must fail closed; out=$out"
    fi
}

# EX-2: ALLOW-looking JSON on stderr + REJECT on stdout → stdout wins → NO token (stderr can't supply a verdict).
# BOTH objects carry the invocation nonce, so the assertion is genuinely about the
# stdout/stderr channel split — an unauthenticated stderr object would be discarded
# for the wrong reason and the case would pass vacuously.
run_EX2() {
    if ! mint_available; then fail "EX-2: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body="$(examiner_stub_body \
        "$(examiner_verdict_line ALLOW 'sneaky verdict on stderr' '$_n' '>&2')" \
        "$(examiner_verdict_line REJECT 'the real stdout verdict' '$_n')")"
    r=$(exec_req "$tn" "ex2sid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    if [ "$(token_count "$tmp")" -eq 0 ]; then
        pass "EX-2: verdict on stderr is ignored; stdout REJECT governs → NO token minted"
    else
        fail "EX-2: RED-EXPECTED: stderr must not be able to supply an ALLOW verdict; out=$out"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# EX-3: stdout carries no parseable JSON object → empty verdict → REJECT → NO token
run_EX3() {
    if ! mint_available; then fail "EX-3: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
echo "I was unable to reach a decision. There is no JSON here at all."
exit 0
'
    r=$(exec_req "$tn" "ex3sid" "$body" --target workflow --category workflow-bug --detail "bug"); out="${r#*|}"
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'REJECT|no.*parseable|no clearance token' || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-3: unparseable examiner stdout → REJECT (no verdict) → NO token minted"
    else
        fail "EX-3: RED-EXPECTED: unparseable stdout must default to REJECT/no-token; out=$out"
    fi
}

# EX-4: examiner exits 124 (timeout kill) → REJECT timeout path → NO token + off_examination audit
run_EX4() {
    if ! mint_available; then fail "EX-4: RED-EXPECTED (script missing)"; return; fi
    local tmp tn r out body
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    body='#!/usr/bin/env bash
exit 124
'
    r=$(exec_req "$tn" "ex4sid" "$body" --target worktree --category cleanup --detail "cleanup"); out="${r#*|}"
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'timed out|REJECT' || ok=0
    state_has "$tmp" "off_examination" || ok=0
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-4: examiner exit 124 → REJECT (timeout) → NO token + off_examination audit recorded"
    else
        fail "EX-4: RED-EXPECTED: exit-124 must map to REJECT/no-token with an audit entry; out=$out"
    fi
}

# EX-5: run a copy of the script whose SCRIPT_DIR lacks run-with-timeout.sh → UNAVAILABLE → NO token
run_EX5() {
    if ! mint_available; then fail "EX-5: RED-EXPECTED (script missing)"; return; fi
    local tmp tn bindir stubbin r out rc
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    bindir=$(make_tmp)                       # copy of the script only — NO run-with-timeout.sh sibling
    cp "$REQ" "$bindir/request-off-clearance"
    chmod +x "$bindir/request-off-clearance"
    stubbin=$(make_tmp)                       # working codex on PATH so the wrapper check (not codex) is what fails
    write_examiner_stub "$stubbin/codex" ALLOW "would-allow but wrapper missing"
    out=$(PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="ex5sid" CLAUDE_CODE_SESSION_ID="ex5sid" \
        bash "$bindir/request-off-clearance" --target workflow --category workflow-bug --detail "bug" 2>&1)
    rc=$?
    local ok=1
    [ "$(token_count "$tmp")" -eq 0 ] || ok=0
    echo "$out" | grep -qiE 'unavailable|timeout wrapper' || ok=0
    [ "$rc" -ne 0 ] || ok=0
    rm -rf "$tmp" "$bindir" "$stubbin" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "EX-5: missing timeout wrapper → examiner UNAVAILABLE → NO token (even with a working codex)"
    else
        fail "EX-5: RED-EXPECTED: absent run-with-timeout.sh must yield UNAVAILABLE/no-token; rc=$rc out=$out"
    fi
}
