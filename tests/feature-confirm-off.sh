#!/bin/bash
# Tests: bin/confirm-off
# Tags: bin, env, config, tests, scope:common
# L2 tests for bin/confirm-off — thin OFF/ON/ERROR helper wrapping
# get-config-var --is-off, used as the canonical call-site for plan-confirm
# skip checks in skills/.
#
# L3 gap (what this test does NOT catch):
# - real symlink from ~/.local/bin/confirm-off reading the actual user .env
# - pwsh variant behavior (covered by tests/feature-confirm-off.Tests.ps1)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required
#
# Pre-implementation: bin/confirm-off does not exist yet — the fixture cp
# below will fail at runtime until /write-code lands bin/confirm-off.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Build a per-run fixture that mirrors the real layout:
#   $FIX/bin/get-config-var
#   $FIX/bin/confirm-off
#   $FIX/hooks/lib/load-env.js
# Without the lib sibling, get-config-var would return KIND=unloaded and
# confirm-off would always emit ERROR — masking everything.
FIX="$(mktemp -d)"
mkdir -p "$FIX/bin" "$FIX/hooks/lib"
trap 'rm -rf "$FIX"' EXIT

# Pre-implementation: confirm-off not yet written — these will pass once bin/confirm-off is added
cp "$REPO_ROOT/bin/get-config-var" "$FIX/bin/" || { echo "FAIL: cannot copy get-config-var"; exit 1; }
cp "$REPO_ROOT/bin/confirm-off" "$FIX/bin/" || { echo "FAIL: cannot copy confirm-off (expected pre-implementation)"; exit 1; }
cp "$REPO_ROOT/hooks/lib/load-env.js" "$FIX/hooks/lib/" || { echo "FAIL: cannot copy load-env.js"; exit 1; }

chmod +x "$FIX/bin/get-config-var" "$FIX/bin/confirm-off" 2>/dev/null || true

# Helper: write a .env file with one CONFIRM_X=<val> line.
write_env() {
    local val="$1"
    if [ -z "$val" ]; then
        : > "$FIX/.env"
    else
        printf 'CONFIRM_X=%s\n' "$val" > "$FIX/.env"
    fi
}

# Helper: run confirm-off and capture stdout, stderr, exit. Args after the
# function name are forwarded to confirm-off. AGENTS_CONFIG_DIR defaults to
# the fixture; override via OVERRIDE_AGENTS_CONFIG_DIR= for unset/typo cases.
run_co() {
    local desc_unused="$1"; shift
    local cfg="${OVERRIDE_AGENTS_CONFIG_DIR-$FIX}"
    local out_file err_file rc
    out_file="$(mktemp)"; err_file="$(mktemp)"
    if [ "${UNSET_CFG:-0}" = "1" ]; then
        ( unset AGENTS_CONFIG_DIR; run_with_timeout bash "$FIX/bin/confirm-off" "$@" >"$out_file" 2>"$err_file" )
        rc=$?
    else
        AGENTS_CONFIG_DIR="$cfg" run_with_timeout bash "$FIX/bin/confirm-off" "$@" >"$out_file" 2>"$err_file"
        rc=$?
    fi
    CO_OUT="$(cat "$out_file")"; CO_ERR="$(cat "$err_file")"; CO_RC=$rc
    rm -f "$out_file" "$err_file"
}

# Assert helpers
assert_out() {
    local desc="$1" want="$2"
    if [ "$CO_OUT" = "$want" ]; then
        pass "$desc — stdout"
    else
        fail "$desc — expected stdout '$want', got '$CO_OUT'"
    fi
}
assert_rc() {
    local desc="$1" want="$2"
    if [ "$CO_RC" = "$want" ]; then
        pass "$desc — exit $want"
    else
        fail "$desc — expected exit $want, got $CO_RC (stderr: $CO_ERR)"
    fi
}
assert_stderr_nonempty() {
    local desc="$1"
    if [ -n "$CO_ERR" ]; then
        pass "$desc — stderr non-empty"
    else
        fail "$desc — expected non-empty stderr, got empty"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# T01 — .env CONFIRM_X=off → stdout 'OFF', exit 0
# ════════════════════════════════════════════════════════════════════════════
write_env "off"
run_co "T01" CONFIRM_X on
assert_out "T01 .env=off → OFF" "OFF"
assert_rc  "T01 .env=off → exit 0" "0"

# ════════════════════════════════════════════════════════════════════════════
# T01b — env CONFIRM_X="" (empty) does NOT shadow .env=off → OFF, exit 0
# ════════════════════════════════════════════════════════════════════════════
write_env "off"
T01B_OUT="$(mktemp)"; T01B_ERR="$(mktemp)"
( export CONFIRM_X=""; AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on >"$T01B_OUT" 2>"$T01B_ERR" )
T01B_RC=$?
CO_OUT="$(cat "$T01B_OUT")"; CO_ERR="$(cat "$T01B_ERR")"; CO_RC=$T01B_RC
rm -f "$T01B_OUT" "$T01B_ERR"
assert_out "T01b env CONFIRM_X='' does not shadow .env=off → OFF" "OFF"
assert_rc  "T01b env CONFIRM_X='' does not shadow .env=off → exit 0" "0"

# ════════════════════════════════════════════════════════════════════════════
# T02 — .env CONFIRM_X=on → stdout 'ON', exit 1
# ════════════════════════════════════════════════════════════════════════════
write_env "on"
run_co "T02" CONFIRM_X on
assert_out "T02 .env=on → ON" "ON"
assert_rc  "T02 .env=on → exit 1" "1"

# ════════════════════════════════════════════════════════════════════════════
# T03 — no key in .env, default arg 'on' → stdout 'ON', exit 1
# ════════════════════════════════════════════════════════════════════════════
write_env ""
run_co "T03" CONFIRM_X on
assert_out "T03 no key, default on → ON" "ON"
assert_rc  "T03 no key, default on → exit 1" "1"

# ════════════════════════════════════════════════════════════════════════════
# T04 — no key in .env, no default arg → stdout 'ON', exit 1 (fail-safe ON)
# ════════════════════════════════════════════════════════════════════════════
write_env ""
run_co "T04" CONFIRM_X
assert_out "T04 no key, no default → ON" "ON"
assert_rc  "T04 no key, no default → exit 1" "1"

# ════════════════════════════════════════════════════════════════════════════
# T05 — .env CONFIRM_X=unknown → stdout 'ON', exit 1 + stderr warning
# ════════════════════════════════════════════════════════════════════════════
write_env "unknown"
run_co "T05" CONFIRM_X on
assert_out "T05 unrecognized → ON" "ON"
assert_rc  "T05 unrecognized → exit 1" "1"
assert_stderr_nonempty "T05 unrecognized → stderr warning"

# ════════════════════════════════════════════════════════════════════════════
# T06 — AGENTS_CONFIG_DIR unset entirely → stdout 'ERROR', exit 2 + stderr
# ════════════════════════════════════════════════════════════════════════════
# Use a temp HOME with no agents installation; copy confirm-off to an
# isolated dir so the SCRIPT_DIR fallback in get-config-var also fails.
ISO_DIR="$(mktemp -d)"
mkdir -p "$ISO_DIR/bin"
cp "$REPO_ROOT/bin/get-config-var" "$ISO_DIR/bin/"
cp "$REPO_ROOT/bin/confirm-off" "$ISO_DIR/bin/" 2>/dev/null || true
chmod +x "$ISO_DIR/bin/get-config-var" "$ISO_DIR/bin/confirm-off" 2>/dev/null || true
T06_OUT="$(mktemp)"; T06_ERR="$(mktemp)"
( unset AGENTS_CONFIG_DIR; run_with_timeout bash "$ISO_DIR/bin/confirm-off" CONFIRM_X on >"$T06_OUT" 2>"$T06_ERR" )
T06_RC=$?
CO_OUT="$(cat "$T06_OUT")"; CO_ERR="$(cat "$T06_ERR")"; CO_RC=$T06_RC
rm -f "$T06_OUT" "$T06_ERR"; rm -rf "$ISO_DIR"
assert_out "T06 AGENTS_CONFIG_DIR unset → ERROR" "ERROR"
assert_rc  "T06 AGENTS_CONFIG_DIR unset → exit 2" "2"
assert_stderr_nonempty "T06 AGENTS_CONFIG_DIR unset → stderr diagnostic"

# ════════════════════════════════════════════════════════════════════════════
# T6b — AGENTS_CONFIG_DIR exists but bin/get-config-var missing → ERROR, exit 2
# ════════════════════════════════════════════════════════════════════════════
# Create a fresh temp dir with no bin/ subdirectory inside (no get-config-var).
# confirm-off must detect the missing binary and output ERROR + exit 2.
T6B_DIR="$(mktemp -d)"
# No bin/ created — directory exists but get-config-var is absent.
T6B_ISO="$(mktemp -d)"
mkdir -p "$T6B_ISO/bin"
cp "$REPO_ROOT/bin/confirm-off" "$T6B_ISO/bin/" 2>/dev/null || true
chmod +x "$T6B_ISO/bin/confirm-off" 2>/dev/null || true
T6B_OUT="$(mktemp)"; T6B_ERR="$(mktemp)"
AGENTS_CONFIG_DIR="$T6B_DIR" run_with_timeout bash "$T6B_ISO/bin/confirm-off" CONFIRM_X on >"$T6B_OUT" 2>"$T6B_ERR"
T6B_RC=$?
CO_OUT="$(cat "$T6B_OUT")"; CO_ERR="$(cat "$T6B_ERR")"; CO_RC=$T6B_RC
rm -f "$T6B_OUT" "$T6B_ERR"; rm -rf "$T6B_DIR" "$T6B_ISO"
assert_out "T6b AGENTS_CONFIG_DIR exists, get-config-var missing → ERROR" "ERROR"
assert_rc  "T6b AGENTS_CONFIG_DIR exists, get-config-var missing → exit 2" "2"

# ════════════════════════════════════════════════════════════════════════════
# T07 — AGENTS_CONFIG_DIR set to nonexistent path → stdout 'ERROR', exit 2
# ════════════════════════════════════════════════════════════════════════════
# Run confirm-off from an isolated dir so SCRIPT_DIR fallback ALSO fails.
ISO2_DIR="$(mktemp -d)"
mkdir -p "$ISO2_DIR/bin"
cp "$REPO_ROOT/bin/get-config-var" "$ISO2_DIR/bin/"
cp "$REPO_ROOT/bin/confirm-off" "$ISO2_DIR/bin/" 2>/dev/null || true
chmod +x "$ISO2_DIR/bin/get-config-var" "$ISO2_DIR/bin/confirm-off" 2>/dev/null || true
T07_OUT="$(mktemp)"; T07_ERR="$(mktemp)"
AGENTS_CONFIG_DIR="/nonexistent/path/$$" run_with_timeout bash "$ISO2_DIR/bin/confirm-off" CONFIRM_X on >"$T07_OUT" 2>"$T07_ERR"
T07_RC=$?
CO_OUT="$(cat "$T07_OUT")"; CO_ERR="$(cat "$T07_ERR")"; CO_RC=$T07_RC
rm -f "$T07_OUT" "$T07_ERR"; rm -rf "$ISO2_DIR"
assert_out "T07 AGENTS_CONFIG_DIR nonexistent → ERROR" "ERROR"
assert_rc  "T07 AGENTS_CONFIG_DIR nonexistent → exit 2" "2"

# ════════════════════════════════════════════════════════════════════════════
# T08 — no args → exit 64, usage to stderr
# ════════════════════════════════════════════════════════════════════════════
T08_OUT="$(mktemp)"; T08_ERR="$(mktemp)"
AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" >"$T08_OUT" 2>"$T08_ERR"
T08_RC=$?
CO_OUT="$(cat "$T08_OUT")"; CO_ERR="$(cat "$T08_ERR")"; CO_RC=$T08_RC
rm -f "$T08_OUT" "$T08_ERR"
assert_rc  "T08 no args → exit 64" "64"
assert_stderr_nonempty "T08 no args → usage to stderr"

# ════════════════════════════════════════════════════════════════════════════
# T09 — process.env wins: shell env CONFIRM_X=off + .env CONFIRM_X=on → OFF
# ════════════════════════════════════════════════════════════════════════════
write_env "on"
T09_OUT="$(mktemp)"; T09_ERR="$(mktemp)"
( export CONFIRM_X=off; AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on >"$T09_OUT" 2>"$T09_ERR" )
T09_RC=$?
CO_OUT="$(cat "$T09_OUT")"; CO_ERR="$(cat "$T09_ERR")"; CO_RC=$T09_RC
rm -f "$T09_OUT" "$T09_ERR"
assert_out "T09 process.env wins (=off vs .env=on) → OFF" "OFF"
assert_rc  "T09 process.env wins → exit 0" "0"

# ════════════════════════════════════════════════════════════════════════════
# T10–T13 — Vocabulary narrowing: legacy synonyms now treated as ON
# ════════════════════════════════════════════════════════════════════════════
for legacy in "0:T10" "false:T11" "no:T12" "disabled:T13"; do
    val="${legacy%%:*}"; tid="${legacy##*:}"
    write_env "$val"
    run_co "$tid" CONFIRM_X on
    assert_out "$tid .env=$val → ON (vocabulary narrowed)" "ON"
    assert_rc  "$tid .env=$val → exit 1" "1"
done

# ════════════════════════════════════════════════════════════════════════════
# T14–T16 — Caller idiom verification: `OUT=$(confirm-off ...) || true`
# Parent shell must always end exit 0 (|| true consumes non-zero).
# ════════════════════════════════════════════════════════════════════════════

# T14: .env=off → OUT=OFF, parent exit 0
write_env "off"
OUT="$(AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on 2>/dev/null)" || true
T14_RC=$?
if [ "$OUT" = "OFF" ]; then
    pass "T14 caller idiom .env=off → OUT=OFF"
else
    fail "T14 caller idiom .env=off → expected OUT=OFF, got '$OUT'"
fi
if [ "$T14_RC" = "0" ]; then
    pass "T14 caller idiom parent exit 0"
else
    fail "T14 caller idiom — expected parent exit 0, got $T14_RC"
fi

# T15: .env=on → OUT=ON, parent exit 0 (|| true consumed exit 1)
write_env "on"
OUT="$(AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on 2>/dev/null)" || true
T15_RC=$?
if [ "$OUT" = "ON" ]; then
    pass "T15 caller idiom .env=on → OUT=ON"
else
    fail "T15 caller idiom .env=on → expected OUT=ON, got '$OUT'"
fi
if [ "$T15_RC" = "0" ]; then
    pass "T15 caller idiom parent exit 0"
else
    fail "T15 caller idiom — expected parent exit 0, got $T15_RC"
fi

# T16: AGENTS_CONFIG_DIR unset → OUT=ERROR, parent exit 0 (|| true consumed exit 2)
ISO3_DIR="$(mktemp -d)"
mkdir -p "$ISO3_DIR/bin"
cp "$REPO_ROOT/bin/get-config-var" "$ISO3_DIR/bin/"
cp "$REPO_ROOT/bin/confirm-off" "$ISO3_DIR/bin/" 2>/dev/null || true
chmod +x "$ISO3_DIR/bin/get-config-var" "$ISO3_DIR/bin/confirm-off" 2>/dev/null || true
OUT="$( ( unset AGENTS_CONFIG_DIR; run_with_timeout bash "$ISO3_DIR/bin/confirm-off" CONFIRM_X on 2>/dev/null ) )" || true
T16_RC=$?
rm -rf "$ISO3_DIR"
if [ "$OUT" = "ERROR" ]; then
    pass "T16 caller idiom unset cfg → OUT=ERROR"
else
    fail "T16 caller idiom unset cfg → expected OUT=ERROR, got '$OUT'"
fi
if [ "$T16_RC" = "0" ]; then
    pass "T16 caller idiom parent exit 0 (|| true consumed)"
else
    fail "T16 caller idiom — expected parent exit 0, got $T16_RC"
fi

# ════════════════════════════════════════════════════════════════════════════
# T17 — Regression smoke: no remaining `get-config-var --is-off` in skills/
# This verifies the call-site migration to confirm-off has completed. Will
# FAIL until /write-code rewrites every skill that currently uses the old
# 3-clause idiom.
# ════════════════════════════════════════════════════════════════════════════
T17_HITS="$(grep -rln 'get-config-var --is-off' "$REPO_ROOT/skills/" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$T17_HITS" = "0" ]; then
    pass "T17 no get-config-var --is-off remaining in skills/"
else
    fail "T17 expected 0 matches of 'get-config-var --is-off' in skills/, found $T17_HITS"
fi

# ════════════════════════════════════════════════════════════════════════════
# T18 — Idempotency: running twice with same .env returns same stdout+exit
# ════════════════════════════════════════════════════════════════════════════
write_env "off"
T18A_OUT="$(AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on 2>/dev/null)" || true
T18A_RC=$?
T18B_OUT="$(AGENTS_CONFIG_DIR="$FIX" run_with_timeout bash "$FIX/bin/confirm-off" CONFIRM_X on 2>/dev/null)" || true
T18B_RC=$?
if [ "$T18A_OUT" = "$T18B_OUT" ] && [ "$T18A_RC" = "$T18B_RC" ]; then
    pass "T18 idempotency: both runs returned '$T18A_OUT' / exit $T18A_RC"
else
    fail "T18 idempotency mismatch: run1='$T18A_OUT'/$T18A_RC vs run2='$T18B_OUT'/$T18B_RC"
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "=== feature-confirm-off: ALL PASS ==="
else
    echo "=== feature-confirm-off: $ERRORS FAIL ==="
fi
exit "$ERRORS"
