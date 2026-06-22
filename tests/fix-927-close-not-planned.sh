#!/bin/bash
# Tests: bin/github-issues/close-not-planned.sh
# Tags: close-not-planned, issue-close-migrated, scope:issue-specific
#
# Argument-validation pre-condition tests.
# All tested paths exit 1 before any gh call is made.
#
# L3 gap (what this test does NOT catch):
# - Happy path: actual label apply, comment post, and gh issue close via real GitHub API
# - Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/bin/github-issues/close-not-planned.sh"

pass=0
fail=0

run_case() {
    local label="$1"; shift
    local expected_exit="$1"; shift
    # remaining args forwarded to the script

    actual_exit=0
    bash "$SCRIPT" "$@" >/dev/null 2>&1 || actual_exit=$?

    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        echo "PASS: $label"
        ((pass++)) || true
    else
        echo "FAIL: $label — expected exit $expected_exit, got $actual_exit"
        ((fail++)) || true
    fi
}

# P1: --type migrated without --into → exit 1 (before any gh call)
run_case "P1: migrated without --into" 1 \
    --type migrated 999

# P2: --type cancelled with --into N → exit 1 (before any gh call)
run_case "P2: cancelled with --into" 1 \
    --type cancelled --into 123 999

# P3: unknown --type foo → exit 1 (before any gh call)
run_case "P3: unknown type foo" 1 \
    --type foo 999

# P4: missing issue number (no positional) → exit 1 (before any gh call)
run_case "P4: missing issue number" 1 \
    --type cancelled

# P5: --type migrated --into 123 with missing N positional → exit 1 (before any gh call)
run_case "P5: migrated --into present but N missing" 1 \
    --type migrated --into 123

# P6: source issue is CLOSED → exit 1 with error mentioning OPEN
_tmp_p6=$(mktemp -d)
printf '#!/bin/bash\necho "CLOSED"\n' > "$_tmp_p6/gh"
chmod +x "$_tmp_p6/gh"
_rc_p6=0
_out_p6=$(PATH="$_tmp_p6:$PATH" bash "$SCRIPT" --type cancelled 999 2>&1) || _rc_p6=$?
if [[ "$_rc_p6" -eq 1 ]] && echo "$_out_p6" | grep -qi "OPEN"; then
    echo "PASS: P6: closed source issue → exit 1"
    ((pass++)) || true
else
    echo "FAIL: P6: closed source issue (rc=$_rc_p6 out=$_out_p6)"
    ((fail++)) || true
fi
rm -rf "$_tmp_p6"

# P7: source OPEN but destination CLOSED (--type migrated --into 222 111) → exit 1
_tmp_p7=$(mktemp -d)
cat > "$_tmp_p7/gh" << 'GHEOF'
#!/bin/bash
# Return OPEN for issue 111, CLOSED for issue 222
if [[ "$*" == *"111"* ]]; then echo "OPEN"; else echo "CLOSED"; fi
GHEOF
chmod +x "$_tmp_p7/gh"
_rc_p7=0
_out_p7=$(PATH="$_tmp_p7:$PATH" bash "$SCRIPT" --type migrated --into 222 111 2>&1) || _rc_p7=$?
if [[ "$_rc_p7" -eq 1 ]] && echo "$_out_p7" | grep -qi "OPEN"; then
    echo "PASS: P7: closed destination issue → exit 1"
    ((pass++)) || true
else
    echo "FAIL: P7: closed destination issue (rc=$_rc_p7 out=$_out_p7)"
    ((fail++)) || true
fi
rm -rf "$_tmp_p7"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
