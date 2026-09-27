#!/usr/bin/env bash
# tests/bin/feature-2374-off-clearance-fallback.sh
# Tests: bin/request-off-clearance
# Tags: off-clearance, examiner, fallback, human-approval, audit, exit-codes, security, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:size-hard-limit

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib/request-off-clearance-harness.sh
. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"

# TL3 gap (what this test does NOT catch):
# - Real /dev/tty interactive approval (TTY unavailable in Claude Code Bash tool)
# - Real codex CLI behavior (all stubs here); actual 401/network error formats from codex
# - Timeout fallback: codex stub that genuinely hangs (run-with-timeout wraps at process level)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
# dup-group-keep:size-hard-limit — appending to fix-1780-round12-cli-lifecycle.sh
# (477 lines) would exceed the 500-line HARD limit.

offclr_require_script

# ============================================================================
# FB - EXAMINER FALLBACK (#2374). codex unavailable is de-SPOF'd two ways: a
# human-approval fallback (OFFCLR_APPROVAL_INPUT, non-interactive so TL2-testable)
# and classify_codex_failure bucketing the failure so the audit says WHY.
# Each case asserts exit code + audit record + (negative paths) emergency hint.
# The class-vs-UNAVAILABLE OR keeps rows valid before the classifier lands
# (audit carries UNAVAILABLE) and after (audit carries class=<x>).
# ============================================================================

# codex_fail_stub <stderr-line> — a codex that emits ONE stderr line and exits 1,
# never a verdict. This is the raw material classify_codex_failure must bucket.
codex_fail_stub() {
    printf '#!/usr/bin/env bash\necho %s >&2\nexit 1\n' "$(printf '%q' "$1")"
}

# state_has_any <dir> <pattern>... — true when ANY pattern is in the audit trail.
state_has_any() {
    local dir="$1"; shift
    local p
    for p in "$@"; do
        state_has "$dir" "$p" && return 0
    done
    return 1
}

# assert_contains <name> <want-substring> <got> — pass when want is a substring
# of got. Complements the harness's exact-match assert_eq for reason-binding
# assertions where the field carries extra structure around the human text.
assert_contains() {
    local name="$1" want="$2" got="$3"
    if printf '%s' "$got" | grep -qF "$want"; then pass "$name"
    else fail "$name - want to find '$(printf '%q' "$want")' in '$(printf '%q' "$got")'"; fi
}

run_FB_fallback() {
    local tmp tn ok

    # FB-1 codex absent, no approval input, no TTY -> UNAVAILABLE with the
    # not-found class, and the emergency escalation is offered. Fail-closed: a
    # broken examiner and no reachable human must NOT mint a token.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="fb1sid"; REQ_NO_EXAMINER=1
    run_req "$tn" "" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    echo "$OUT$ERR" | grep -qE "EMERGENCY|/enforce-workflow-off" || ok=0
    state_has "$tmp" "UNAVAILABLE" || ok=0
    state_has "$tmp" "not-found" || ok=0
    [ "$(token_count "$tmp")" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-1 codex absent + no approval + no TTY -> RC1, UNAVAILABLE/not-found audited, emergency hint, NO token"
    else
        fail "FB-1 want rc=1 + UNAVAILABLE + not-found + emergency hint + no token; got rc=$RC tokens=$(token_count "$tmp") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-2 codex fails with a 401 signature -> auth-401 class. The audit must
    # record examiner=auth-401 (not a generic UNAVAILABLE) so taxonomy is pinned.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="fb2sid"
    run_req "$tn" "$(codex_fail_stub '401 Unauthorized')" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    state_has "$tmp" "examiner=auth-401" || ok=0
    [ "$(token_count "$tmp")" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-2 codex 401 -> RC1, examiner=auth-401 audited, NO token"
    else
        fail "FB-2 want rc=1 + examiner=auth-401 + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-3 codex fails with a connection-refused signature -> network class pinned.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="fb3sid"
    run_req "$tn" "$(codex_fail_stub 'connect ECONNREFUSED 127.0.0.1:443')" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    state_has "$tmp" "examiner=network" || ok=0
    [ "$(token_count "$tmp")" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-3 codex ECONNREFUSED -> RC1, examiner=network audited, NO token"
    else
        fail "FB-3 want rc=1 + examiner=network + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-4 codex fails with an unrecognized signature -> unknown class pinned.
    # The classifier must have a catch-all bucket rather than dropping the reason.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    REQ_SID="fb4sid"
    run_req "$tn" "$(codex_fail_stub 'some unexpected failure')" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    state_has "$tmp" "examiner=unknown" || ok=0
    [ "$(token_count "$tmp")" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-4 codex unrecognized stderr -> RC1, examiner=unknown audited, NO token"
    else
        fail "FB-4 want rc=1 + examiner=unknown + no token; got rc=$RC tokens=$(token_count "$tmp") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-5 codex absent BUT a human approval reason is supplied out-of-band via
    # OFFCLR_APPROVAL_INPUT -> ALLOW, token minted. This is the SPOF fix: a
    # reachable human can grant clearance even with the examiner down.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    printf 'legitimate workflow-off reason\n' > "$tmp/approval_input.txt"
    REQ_SID="fb5sid"; REQ_NO_EXAMINER=1
    REQ_ENV=("OFFCLR_APPROVAL_INPUT=$(node_path "$tmp/approval_input.txt")")
    run_req "$tn" "" --target workflow --category workflow-bug --detail "bug"
    ok=1
    [ "$RC" -eq 0 ] || ok=0
    state_has "$tmp" "ALLOW" || ok=0
    [ "$(token_count "$tmp")" = "1" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-5 codex absent + human approval reason -> RC0, ALLOW audited, token minted"
    else
        fail "FB-5 want rc=0 + ALLOW + 1 token; got rc=$RC tokens=$(token_count "$tmp") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-6 codex absent and the approval input is EMPTY -> no human reason, so
    # the fallback declines: UNAVAILABLE, emergency hint, NO token. An empty file
    # is not a silent ALLOW.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    printf '' > "$tmp/approval_input.txt"
    REQ_SID="fb6sid"; REQ_NO_EXAMINER=1
    REQ_ENV=("OFFCLR_APPROVAL_INPUT=$(node_path "$tmp/approval_input.txt")")
    run_req "$tn" "" --target worktree --category cleanup --detail "leftovers"
    ok=1
    [ "$RC" -eq 1 ] || ok=0
    state_has "$tmp" "UNAVAILABLE" || ok=0
    echo "$OUT$ERR" | grep -qE "EMERGENCY|/enforce-workflow-off" || ok=0
    [ "$(token_count "$tmp")" = "0" ] || ok=0
    if [ "$ok" = "1" ]; then
        pass "FB-6 codex absent + empty approval input -> RC1, UNAVAILABLE audited, emergency hint, NO token"
    else
        fail "FB-6 want rc=1 + UNAVAILABLE + emergency hint + no token; got rc=$RC tokens=$(token_count "$tmp") out=$(printf '%q' "$OUT") err=$(printf '%q' "$ERR")"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-X codex is PRESENT but exits non-zero (401 stub) AND a human approval
    # reason is supplied via OFFCLR_APPROVAL_INPUT -> ALLOW, token minted. FB-5
    # exercises the codex-ABSENT fallback (REQ_NO_EXAMINER); this exercises the
    # DISTINCT run-then-nonzero path: command -v codex succeeds, codex runs and
    # fails, classify_codex_failure buckets it, then human_approval_fallback
    # grants clearance. The token's reason must carry the human text (provenance).
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    printf 'human-approved reason for auth failure\n' > "$tmp/approval.txt"
    REQ_SID="fbXsid"
    REQ_ENV=("OFFCLR_APPROVAL_INPUT=$(node_path "$tmp/approval.txt")")
    run_req "$tn" "$(codex_fail_stub '401 Unauthorized')" --target workflow --category workflow-bug --detail "bug"
    assert_eq "FB-X codex-nonzero-fallback + approval-input exits 0" "0" "$RC"
    state_has "$tmp" "ALLOW" && pass "FB-X audit records ALLOW" || fail "FB-X audit records ALLOW"
    assert_eq "FB-X token minted" "1" "$(token_count "$tmp")"
    # human reason binding: the minted token's reason field must contain the
    # approval text, proving the fallback recorded WHO/WHY, not a bare ALLOW.
    _token_file=$(ls "$tmp"/*.off-clearance 2>/dev/null | head -1)
    if [ -n "$_token_file" ]; then
        _reason=$(offclr_json "$(node_path "$_token_file")" 't.reason || t.verdict_reason || ""')
        assert_contains "FB-X token reason contains human approval text" "human-approved reason" "$_reason"
    else
        fail "FB-X token reason contains human approval text - no token file to inspect"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # FB-Y codex absent + human approval reason + --target worktree -> ALLOW,
    # worktree token minted. FB-5 covers the same fallback for --target workflow;
    # CPR-ORTH: the worktree target is a symmetric sibling and must mint too.
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    printf 'legitimate worktree cleanup reason\n' > "$tmp/approval.txt"
    REQ_SID="fbYsid"; REQ_NO_EXAMINER=1
    REQ_ENV=("OFFCLR_APPROVAL_INPUT=$(node_path "$tmp/approval.txt")")
    run_req "$tn" "" --target worktree --category cleanup --detail "stale worktrees"
    assert_eq "FB-Y worktree-target fallback + approval-input exits 0" "0" "$RC"
    state_has "$tmp" "ALLOW" && pass "FB-Y audit records ALLOW" || fail "FB-Y audit records ALLOW"
    assert_eq "FB-Y worktree token minted" "1" "$(token_count "$tmp")"
    _token_file_y=$(ls "$tmp"/*.off-clearance 2>/dev/null | head -1)
    if [ -n "$_token_file_y" ]; then
        _target_y=$(offclr_json "$(node_path "$_token_file_y")" 't.target || t.category_target || ""')
        assert_contains "FB-Y token target field is worktree" "worktree" "$_target_y"
    else
        skip "FB-Y token target field is worktree — token not yet minted (implementation pending)"
    fi
    rm -r -f "$tmp" 2>/dev/null || true

    # SKIPPED: interactive TTY approval (real /dev/tty)
    # Because: Claude Code Bash tool has no /dev/tty; fault injection not possible at TL2
    # TL3 gap: actual real-tty interactive prompt, /dev/tty read blocking behavior
    skip "FB interactive /dev/tty approval — no TTY in Claude Code Bash tool (TL3 gap)"
}

run_FB_fallback

offclr_report
