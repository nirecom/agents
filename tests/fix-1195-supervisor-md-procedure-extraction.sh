#!/bin/bash
# tests/fix-1195-supervisor-md-procedure-extraction.sh
# Tests: bin/supervisor-check-session-active, bin/supervisor-finalize-verify, bin/supervisor-parse-codex, agents/supervisor.md
# Tags: supervisor, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
#   These are L2 integration tests. L3 would require a real `claude -p` session
#   to verify the full Stop-hook → supervisor-guard → supervisor agent flow:
#   specifically that supervisor.md's bin/ references actually invoke correctly
#   in a live session, and that supervisor-finalize-verify is called at the
#   right point in the Phase 3 post-condition check flow.
#   Closest-to-action mitigation: skill-orchestration category in
#   bin/check-verification-gate.sh.
#
# RED: All tests fail until write_code creates the source scripts and updates
# agents/supervisor.md. That is expected — this is TDD.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
    _TMPCONV() { cygpath -m "$1"; }
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
    _TMPCONV() { printf '%s' "$1"; }
fi

CHECK_SESSION="$AGENTS_DIR/bin/supervisor-check-session-active"
FINALIZE_VERIFY="$AGENTS_DIR/bin/supervisor-finalize-verify"
PARSE_CODEX="$AGENTS_DIR/bin/supervisor-parse-codex"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"
PARSE_CLOSES_ISSUES_NODE="$_AGENTS_DIR_NODE/hooks/lib/parse-closes-issues.js"
CODEX_PARSE_NODE="$_AGENTS_DIR_NODE/hooks/lib/codex-review-parse.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# ---------------------------------------------------------------------------
# A — bin/supervisor-check-session-active
# ---------------------------------------------------------------------------

# A1: empty closes_issues list → exit 0 (active path)
run_a1() {
    local label="A1: empty closes_issues → exit 0 (active path)"
    require_source "$CHECK_SESSION" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    # intent.md with empty ## Issues section
    cat > "$tmp/test-wsid-a1-intent.md" <<'INTENT'
## Issues

## Scope
test scope
INTENT

    # Create fake gh that must not be called (if it is called, it would fail).
    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<'FAKEGH'
#!/bin/bash
echo "ERROR: gh must not be called for empty issues list" >&2
exit 99
FAKEGH
    chmod +x "$fake_bin/gh"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$CHECK_SESSION" "test-wsid-a1" > /dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (expected exit 0, got $rc)"
    fi
}

# A2: intent.md with OPEN issues → exit 0 (active path)
run_a2() {
    local label="A2: intent.md with OPEN issues → exit 0"
    require_source "$CHECK_SESSION" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/test-wsid-a2-intent.md" <<'INTENT'
## Issues

- #100
- #101
INTENT

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    # Mock gh: all issues return OPEN
    cat > "$fake_bin/gh" <<'FAKEGH'
#!/bin/bash
echo "OPEN"
exit 0
FAKEGH
    chmod +x "$fake_bin/gh"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$CHECK_SESSION" "test-wsid-a2" > /dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (expected exit 0, got $rc)"
    fi
}

# A3: all issues CLOSED → exit 1 (terminated session)
run_a3() {
    local label="A3: all issues CLOSED → exit 1 (terminated session)"
    require_source "$CHECK_SESSION" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/test-wsid-a3-intent.md" <<'INTENT'
## Issues

- #200
- #201
INTENT

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    # Mock gh: all issues return CLOSED
    cat > "$fake_bin/gh" <<'FAKEGH'
#!/bin/bash
echo "CLOSED"
exit 0
FAKEGH
    chmod +x "$fake_bin/gh"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$CHECK_SESSION" "test-wsid-a3" > /dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 1 ]; then
        pass "$label"
    else
        fail "$label (expected exit 1, got $rc)"
    fi
}

# A4: mixed OPEN+CLOSED → exit 0 (any OPEN = active)
run_a4() {
    local label="A4: mixed OPEN+CLOSED → exit 0 (any OPEN = active)"
    require_source "$CHECK_SESSION" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/test-wsid-a4-intent.md" <<'INTENT'
## Issues

- #300
- #301
- #302
INTENT

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    # Mock gh: issue 301 is OPEN, others CLOSED
    # Use a counter to alternate responses
    local counter_file="$tmp/call-count"
    echo 0 > "$counter_file"
    cat > "$fake_bin/gh" <<FAKEGH
#!/bin/bash
count=\$(cat "$counter_file")
count=\$((count + 1))
echo \$count > "$counter_file"
if [ "\$count" -eq 2 ]; then
    echo "OPEN"
else
    echo "CLOSED"
fi
exit 0
FAKEGH
    chmod +x "$fake_bin/gh"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$CHECK_SESSION" "test-wsid-a4" > /dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (expected exit 0, got $rc)"
    fi
}

# A5: intent.md not found → exit 0 (fail-safe)
run_a5() {
    local label="A5: intent.md not found → exit 0 (fail-safe)"
    require_source "$CHECK_SESSION" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    # No intent.md file created

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/gh" <<'FAKEGH'
#!/bin/bash
echo "ERROR: gh must not be called when intent.md missing" >&2
exit 99
FAKEGH
    chmod +x "$fake_bin/gh"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$CHECK_SESSION" "test-wsid-a5-missing" > /dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "$label"
    else
        fail "$label (expected exit 0 fail-safe, got $rc)"
    fi
}

# A6: structural — file exists and is executable
run_a6() {
    local label="A6: bin/supervisor-check-session-active exists and is executable"
    if [ ! -f "$CHECK_SESSION" ]; then
        fail "$label (file does not exist: $CHECK_SESSION)"
        return
    fi
    if [ ! -x "$CHECK_SESSION" ]; then
        fail "$label (file is not executable: $CHECK_SESSION)"
        return
    fi
    pass "$label"
}

# ---------------------------------------------------------------------------
# B — bin/supervisor-finalize-verify
# ---------------------------------------------------------------------------

# Helper: seed a minimal supervisor-state.json in a temp dir
seed_state_json() {
    local tmp="$1" sid="$2" alert_phase="$3" alert_armed_at="$4"
    local state_file="$tmp/${sid}-supervisor-state.json"
    local armed_value
    if [ "$alert_armed_at" = "null" ]; then
        armed_value="null"
    else
        armed_value="\"$alert_armed_at\""
    fi
    cat > "$state_file" <<STATE
{
  "alert": {
    "alert_phase": "$alert_phase",
    "alert_armed_at": $armed_value,
    "findings": [],
    "cumulative_severity": null,
    "last_run_at": null,
    "alert_retry_count": 0
  }
}
STATE
}

# B7: state has alert_phase=done and alert_armed_at=null → exit 0, no retry
run_b7() {
    local label="B7: alert_phase=done + alert_armed_at=null → exit 0 no retry"
    require_source "$FINALIZE_VERIFY" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    local sid="test-b7sid"
    seed_state_json "$tmp" "$sid" "done" "null"

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    local invoc_file="$tmp/write-alert-invoked"
    # supervisor-write-alert mock: record invocation
    cat > "$fake_bin/supervisor-write-alert" <<FAKEWA
#!/bin/bash
echo "invoked" >> "$invoc_file"
exit 0
FAKEWA
    chmod +x "$fake_bin/supervisor-write-alert"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$FINALIZE_VERIFY" "$sid" > /dev/null 2>&1
    rc=$?

    local retried=0
    [ -f "$invoc_file" ] && retried=1
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ $retried -eq 0 ]; then
        pass "$label"
    else
        fail "$label (exit=$rc, retried=$retried; expected exit 0, no retry)"
    fi
}

# B8: alert_phase != done → retries with supervisor-write-alert, still fails → exit 1
run_b8() {
    local label="B8: alert_phase=pending → retries, exits 1"
    require_source "$FINALIZE_VERIFY" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    local sid="test-b8sid"
    seed_state_json "$tmp" "$sid" "pending" "null"

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    local invoc_file="$tmp/write-alert-invoked"
    # supervisor-write-alert mock: record invocation but do NOT change state
    cat > "$fake_bin/supervisor-write-alert" <<FAKEWA
#!/bin/bash
echo "invoked" >> "$invoc_file"
exit 0
FAKEWA
    chmod +x "$fake_bin/supervisor-write-alert"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$FINALIZE_VERIFY" "$sid" > /dev/null 2>&1
    rc=$?

    local retried=0
    [ -f "$invoc_file" ] && retried=1
    rm -rf "$tmp"
    if [ $rc -eq 1 ] && [ $retried -eq 1 ]; then
        pass "$label"
    else
        fail "$label (exit=$rc, retried=$retried; expected exit 1 with retry invoked)"
    fi
}

# B9: alert_armed_at non-null but alert_phase=done → verifies retry clears it
run_b9() {
    local label="B9: alert_armed_at non-null with alert_phase=done → retry called, exits 1"
    require_source "$FINALIZE_VERIFY" "$label" || return
    local tmp
    tmp="$(mktemp -d)"
    local sid="test-b9sid"
    seed_state_json "$tmp" "$sid" "done" "2026-06-28T00:00:00.000Z"

    local fake_bin="$tmp/fake-bin"
    mkdir -p "$fake_bin"
    local invoc_file="$tmp/write-alert-invoked"
    # supervisor-write-alert mock: record invocation but state file stays unchanged
    cat > "$fake_bin/supervisor-write-alert" <<FAKEWA
#!/bin/bash
echo "invoked" >> "$invoc_file"
exit 0
FAKEWA
    chmod +x "$fake_bin/supervisor-write-alert"

    local rc
    WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")" \
        PATH="$fake_bin:$PATH" \
        run_with_timeout 10 "$FINALIZE_VERIFY" "$sid" > /dev/null 2>&1
    rc=$?

    local retried=0
    [ -f "$invoc_file" ] && retried=1
    rm -rf "$tmp"
    # The script detects alert_armed_at is non-null → retries → state still not cleared → exits 1
    if [ $retried -eq 1 ] && [ $rc -eq 1 ]; then
        pass "$label"
    else
        fail "$label (exit=$rc, retried=$retried; expected retry invoked + exit 1)"
    fi
}

# B10: structural — file exists and is executable
run_b10() {
    local label="B10: bin/supervisor-finalize-verify exists and is executable"
    if [ ! -f "$FINALIZE_VERIFY" ]; then
        fail "$label (file does not exist: $FINALIZE_VERIFY)"
        return
    fi
    if [ ! -x "$FINALIZE_VERIFY" ]; then
        fail "$label (file is not executable: $FINALIZE_VERIFY)"
        return
    fi
    pass "$label"
}

# ---------------------------------------------------------------------------
# C — bin/supervisor-parse-codex
# ---------------------------------------------------------------------------

VALID_CODEX_OUTPUT='<!-- begin-codex-output phase=1 -->
{"idx":1,"verdict":"AGREE","reason":"looks correct"}
{"idx":2,"verdict":"DISAGREE","reason":"wrong assumption"}
<!-- end-codex-output -->'

# C11: valid codex output with begin/end markers → ok:true in JSON
run_c11() {
    local label="C11: valid codex output → ok:true in JSON"
    require_source "$PARSE_CODEX" "$label" || return
    local out rc
    out=$(echo "$VALID_CODEX_OUTPUT" | \
        run_with_timeout 10 node "$PARSE_CODEX" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "$label (script exited $rc: $out)"
        return
    fi
    local ok_val
    ok_val=$(echo "$out" | node -e \
        'let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{try{const p=JSON.parse(d);process.stdout.write(String(p.ok));}catch(e){process.stdout.write("parse-error: "+e.message);}})' \
        2>/dev/null)
    if [ "$ok_val" = "true" ]; then
        pass "$label"
    else
        fail "$label (expected ok:true, got: $ok_val; full output: $out)"
    fi
}

# C12: input with no markers → ok:false in JSON
run_c12() {
    local label="C12: input with no markers → ok:false in JSON"
    require_source "$PARSE_CODEX" "$label" || return
    local out rc
    out=$(echo 'no markers here, just plain text' | \
        run_with_timeout 10 node "$PARSE_CODEX" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "$label (script exited $rc: $out)"
        return
    fi
    local ok_val
    ok_val=$(echo "$out" | node -e \
        'let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{try{const p=JSON.parse(d);process.stdout.write(String(p.ok));}catch(e){process.stdout.write("parse-error: "+e.message);}})' \
        2>/dev/null)
    if [ "$ok_val" = "false" ]; then
        pass "$label"
    else
        fail "$label (expected ok:false, got: $ok_val; full output: $out)"
    fi
}

# C13: empty input → ok:false in JSON
run_c13() {
    local label="C13: empty input → ok:false in JSON"
    require_source "$PARSE_CODEX" "$label" || return
    local out rc
    out=$(echo '' | \
        run_with_timeout 10 node "$PARSE_CODEX" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "$label (script exited $rc: $out)"
        return
    fi
    local ok_val
    ok_val=$(echo "$out" | node -e \
        'let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{try{const p=JSON.parse(d);process.stdout.write(String(p.ok));}catch(e){process.stdout.write("parse-error: "+e.message);}})' \
        2>/dev/null)
    if [ "$ok_val" = "false" ]; then
        pass "$label"
    else
        fail "$label (expected ok:false, got: $ok_val; full output: $out)"
    fi
}

# C14: structural — file exists and is executable
run_c14() {
    local label="C14: bin/supervisor-parse-codex exists and is executable"
    if [ ! -f "$PARSE_CODEX" ]; then
        fail "$label (file does not exist: $PARSE_CODEX)"
        return
    fi
    if [ ! -x "$PARSE_CODEX" ]; then
        fail "$label (file is not executable: $PARSE_CODEX)"
        return
    fi
    pass "$label"
}

# ---------------------------------------------------------------------------
# D — agents/supervisor.md structural
# ---------------------------------------------------------------------------

# D15: supervisor.md references bin/supervisor-check-session-active
run_d15() {
    local label="D15: supervisor.md references bin/supervisor-check-session-active"
    if grep -qF 'supervisor-check-session-active' "$SUPERVISOR_MD"; then
        pass "$label"
    else
        fail "$label (bin/supervisor-check-session-active not referenced in agents/supervisor.md)"
    fi
}

# D16: supervisor.md references bin/supervisor-finalize-verify
run_d16() {
    local label="D16: supervisor.md references bin/supervisor-finalize-verify"
    if grep -qF 'supervisor-finalize-verify' "$SUPERVISOR_MD"; then
        pass "$label"
    else
        fail "$label (bin/supervisor-finalize-verify not referenced in agents/supervisor.md)"
    fi
}

# D17: supervisor.md references bin/supervisor-parse-codex
run_d17() {
    local label="D17: supervisor.md references bin/supervisor-parse-codex"
    if grep -qF 'supervisor-parse-codex' "$SUPERVISOR_MD"; then
        pass "$label"
    else
        fail "$label (bin/supervisor-parse-codex not referenced in agents/supervisor.md)"
    fi
}

# D18: supervisor.md does NOT contain old inline closes_issues gh-loop prose
# The old inline prose described running "gh issue view <N> --json state --jq .state"
# for each N in a loop — this should now live in bin/supervisor-check-session-active.
run_d18() {
    local label="D18: supervisor.md does NOT contain old inline gh-loop closes_issues prose"
    # The old inline prose had this 5-step pattern:
    # "For each N: gh issue view <N> --json state --jq .state"
    if grep -qE 'gh issue view.*--json state.*--jq .state' "$SUPERVISOR_MD"; then
        fail "$label (old inline gh-loop prose still present in supervisor.md)"
    else
        pass "$label"
    fi
}

# D19: supervisor.md Phase 3 post-condition inline retry steps are removed
# The old prose had inline retry steps (numbered 1/2/3) for re-reading and
# re-verifying alert_phase and alert_armed_at — those now live in
# bin/supervisor-finalize-verify.
run_d19() {
    local label="D19: Phase 3 post-condition inline retry steps removed from supervisor.md"
    # The old inline block had this specific 3-step pattern including
    # "Run the finalize call once more" as step 1 of the retry sequence.
    if grep -qF 'Run the finalize call once more' "$SUPERVISOR_MD"; then
        fail "$label (old Phase 3 inline retry steps still present in supervisor.md)"
    else
        pass "$label"
    fi
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------

run_a1
run_a2
run_a3
run_a4
run_a5
run_a6

run_b7
run_b8
run_b9
run_b10

run_c11
run_c12
run_c13
run_c14

run_d15
run_d16
run_d17
run_d18
run_d19

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
