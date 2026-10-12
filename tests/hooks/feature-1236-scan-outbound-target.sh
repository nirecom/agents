#!/bin/bash
# tests/hooks/feature-1236-scan-outbound-target.sh — dispatcher for the forge-write target-visibility gate suite.
# Tests: hooks/lib/forge-write-extract.js, hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
# Parts: part-a.sh (extractRepoFlag unit, table-driven) and part-b.sh (scan-outbound.js with a gh stub:
#   public target + static blocklist = HARD block, dynamic-only = WARN, private target skips the private-info scan
#   but the offensive scan still runs, HARD beats WARN, the body cannot redirect the target).
# L3 gap: real gh visibility lookups, cwd-based target resolution without --repo, cache TTL under concurrency.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
# A part that exits non-zero without printing a FAIL line counts as one failure, so a crash is never green.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$TESTS_DIR/feature-1236-scan-outbound-target"
TOTAL_PASS=0
TOTAL_FAIL=0

run_sub() {
    local out rc
    out="$(bash "$1" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    local p f
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
        echo "FAIL: ${1##*/} crashed (rc=$rc)"
        f=1
    fi
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
}

# Self-check of the aggregation: a part that crashes without a FAIL line must count as a failure,
# and a clean part must not. Runs in a subshell so the deliberate crash never reaches the totals.
SELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SELF_DIR"' EXIT
printf '%s\n' 'echo "PASS: before the crash"' 'exit 3' >"$SELF_DIR/crash.sh"
printf '%s\n' 'echo "PASS: clean"' 'exit 0' >"$SELF_DIR/clean.sh"
for spec in crash.sh:1 clean.sh:0; do
    got="$(run_sub "$SELF_DIR/${spec%%:*}" >/dev/null; echo "$TOTAL_FAIL")"
    if [ "$got" = "${spec##*:}" ]; then echo "PASS: aggregation counts ${spec%%:*} as $got failure(s)"; TOTAL_PASS=$((TOTAL_PASS + 1))
    else echo "FAIL: aggregation counted ${spec%%:*} as $got failure(s), want ${spec##*:}"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); fi
done

# The dispatcher itself must exit non-zero when a part crashes: a copy of this file runs beside a
# crashing part-a and a clean part-b. SCAN_1236_DISPATCH_COPY keeps the copy from recursing.
if [ -z "${SCAN_1236_DISPATCH_COPY:-}" ]; then
    COPY_SUB="$SELF_DIR/copy/feature-1236-scan-outbound-target"
    mkdir -p "$COPY_SUB"
    cp "${BASH_SOURCE[0]}" "$SELF_DIR/copy/dispatcher.sh"
    cp "$SELF_DIR/crash.sh" "$COPY_SUB/part-a.sh"
    cp "$SELF_DIR/clean.sh" "$COPY_SUB/part-b.sh"
    copy_out="$(SCAN_1236_DISPATCH_COPY=1 bash "$SELF_DIR/copy/dispatcher.sh" 2>&1)"
    copy_rc=$?
    if [ "$copy_rc" -ne 0 ] && printf '%s\n' "$copy_out" | grep -q '^FAIL: part-a.sh crashed (rc=3)'; then
        echo "PASS: the dispatcher exits non-zero (rc=$copy_rc) when a part crashes"; TOTAL_PASS=$((TOTAL_PASS + 1))
    else echo "FAIL: the dispatcher exited $copy_rc with a crashing part"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); fi
fi

run_sub "$SUB_DIR/part-a.sh"
run_sub "$SUB_DIR/part-b.sh"

echo ""
echo "================================"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
exit $TOTAL_FAIL
