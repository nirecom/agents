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

# Helper: build the shared capturing gh stub into a temp dir.
# Sets CAPTURE_DIR so the stub can write captured args to files:
#   $CAPTURE_DIR/captured_reason  — value passed to --reason on close
#   $CAPTURE_DIR/captured_edit    — all args passed to "gh issue edit"
#   $CAPTURE_DIR/captured_comment — body passed to "gh issue comment"
_make_capturing_stub() {
    local tmpdir="$1"
    cat > "$tmpdir/gh" << 'GHEOF'
#!/bin/bash
# Stub gh: handles view (returns OPEN), edit, comment, close — captures args.
subcommand="$1"
shift
case "$subcommand" in
    issue)
        action="$1"; shift
        case "$action" in
            view)
                echo "OPEN"
                exit 0
                ;;
            edit)
                echo "$*" > "$CAPTURE_DIR/captured_edit"
                exit 0
                ;;
            comment)
                # Capture the --body value
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "--body" ]]; then
                        shift
                        echo "$1" > "$CAPTURE_DIR/captured_comment"
                        shift
                    else
                        shift
                    fi
                done
                exit 0
                ;;
            close)
                echo "$1" > "$CAPTURE_DIR/captured_close_number"
                shift  # skip issue number
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "--reason" ]]; then
                        shift
                        echo "$1" > "$CAPTURE_DIR/captured_reason"
                        shift
                    else
                        shift
                    fi
                done
                exit 0
                ;;
        esac
        ;;
esac
exit 0
GHEOF
    chmod +x "$tmpdir/gh"
}

# P8: gh issue close must be called with --reason "not planned" (space), NOT not_planned (underscore)
# Regression for #1509: close-not-planned.sh line 63 used not_planned instead of "not planned"
# Also asserts edit adds status:cancelled label and comment body mentions "cancelled".
_tmp_p8=$(mktemp -d)
_make_capturing_stub "$_tmp_p8"

_rc_p8=0
CAPTURE_DIR="$_tmp_p8" PATH="$_tmp_p8:$PATH" bash "$SCRIPT" --type cancelled 999 >/dev/null 2>&1 || _rc_p8=$?

if [[ "$_rc_p8" -ne 0 ]]; then
    echo "FAIL: P8: script exited $_rc_p8, expected 0"
    ((fail++)) || true
elif [[ ! -f "$_tmp_p8/captured_reason" ]]; then
    echo "FAIL: P8: gh issue close --reason was never called"
    ((fail++)) || true
else
    _captured_reason=$(cat "$_tmp_p8/captured_reason")
    if [[ "$_captured_reason" == "not planned" ]]; then
        echo "PASS: P8: gh issue close called with --reason 'not planned'"
        ((pass++)) || true
    elif [[ "$_captured_reason" == "not_planned" ]]; then
        echo "FAIL: P8: gh issue close called with --reason 'not_planned' (underscore) — bug #1509 not fixed"
        ((fail++)) || true
    else
        echo "FAIL: P8: unexpected --reason value: '$_captured_reason'"
        ((fail++)) || true
    fi
fi

# C2/P8a: gh issue edit must add label status:cancelled
if [[ ! -f "$_tmp_p8/captured_edit" ]]; then
    echo "FAIL: P8a: gh issue edit was never called"
    ((fail++)) || true
elif grep -q "status:cancelled" "$_tmp_p8/captured_edit"; then
    echo "PASS: P8a: gh issue edit called with --add-label status:cancelled"
    ((pass++)) || true
else
    echo "FAIL: P8a: gh issue edit did not include status:cancelled (got: $(cat "$_tmp_p8/captured_edit"))"
    ((fail++)) || true
fi

# C2/P8b: gh issue comment body must mention "cancelled"
if [[ ! -f "$_tmp_p8/captured_comment" ]]; then
    echo "FAIL: P8b: gh issue comment was never called"
    ((fail++)) || true
elif grep -qi "cancelled" "$_tmp_p8/captured_comment"; then
    echo "PASS: P8b: gh issue comment body mentions 'cancelled'"
    ((pass++)) || true
else
    echo "FAIL: P8b: gh issue comment body did not mention 'cancelled' (got: $(cat "$_tmp_p8/captured_comment"))"
    ((fail++)) || true
fi

# P8c: gh issue close must target the source issue 999 (not some other number)
if [[ ! -f "$_tmp_p8/captured_close_number" ]]; then
    echo "FAIL: P8c: gh issue close number was never captured"
    ((fail++)) || true
elif [[ "$(cat "$_tmp_p8/captured_close_number")" == "999" ]]; then
    echo "PASS: P8c: gh issue close targeted source issue 999"
    ((pass++)) || true
else
    echo "FAIL: P8c: gh issue close targeted wrong issue (got: $(cat "$_tmp_p8/captured_close_number"))"
    ((fail++)) || true
fi
rm -rf "$_tmp_p8"

# P9: --type migrated --into 111 999 (both OPEN) → close with --reason "not planned" (space)
# Also asserts edit adds status:migrated label.
_tmp_p9=$(mktemp -d)
_make_capturing_stub "$_tmp_p9"

_rc_p9=0
CAPTURE_DIR="$_tmp_p9" PATH="$_tmp_p9:$PATH" bash "$SCRIPT" --type migrated --into 111 999 >/dev/null 2>&1 || _rc_p9=$?

if [[ "$_rc_p9" -ne 0 ]]; then
    echo "FAIL: P9: script exited $_rc_p9, expected 0"
    ((fail++)) || true
elif [[ ! -f "$_tmp_p9/captured_reason" ]]; then
    echo "FAIL: P9: gh issue close --reason was never called"
    ((fail++)) || true
else
    _captured_reason_p9=$(cat "$_tmp_p9/captured_reason")
    if [[ "$_captured_reason_p9" == "not planned" ]]; then
        echo "PASS: P9: gh issue close called with --reason 'not planned'"
        ((pass++)) || true
    elif [[ "$_captured_reason_p9" == "not_planned" ]]; then
        echo "FAIL: P9: gh issue close called with --reason 'not_planned' (underscore) — bug #1509 not fixed"
        ((fail++)) || true
    else
        echo "FAIL: P9: unexpected --reason value: '$_captured_reason_p9'"
        ((fail++)) || true
    fi
fi

# P9z: gh issue comment body must mention "migrated" and the INTO issue number (111)
if [[ ! -f "$_tmp_p9/captured_comment" ]]; then
    echo "FAIL: P9z: gh issue comment was never called"
    ((fail++)) || true
elif grep -qi "migrated" "$_tmp_p9/captured_comment" && grep -q "111" "$_tmp_p9/captured_comment"; then
    echo "PASS: P9z: gh issue comment body mentions 'migrated' and destination 111"
    ((pass++)) || true
else
    echo "FAIL: P9z: gh issue comment body missing 'migrated' or '111' (got: $(cat "$_tmp_p9/captured_comment"))"
    ((fail++)) || true
fi

# C2/P9a: gh issue edit must add label status:migrated
if [[ ! -f "$_tmp_p9/captured_edit" ]]; then
    echo "FAIL: P9a: gh issue edit was never called"
    ((fail++)) || true
elif grep -q "status:migrated" "$_tmp_p9/captured_edit"; then
    echo "PASS: P9a: gh issue edit called with --add-label status:migrated"
    ((pass++)) || true
else
    echo "FAIL: P9a: gh issue edit did not include status:migrated (got: $(cat "$_tmp_p9/captured_edit"))"
    ((fail++)) || true
fi

# P9b: gh issue close must target source issue 999, NOT the INTO destination (111)
if [[ ! -f "$_tmp_p9/captured_close_number" ]]; then
    echo "FAIL: P9b: gh issue close number was never captured"
    ((fail++)) || true
elif [[ "$(cat "$_tmp_p9/captured_close_number")" == "999" ]]; then
    echo "PASS: P9b: gh issue close targeted source issue 999 (not INTO 111)"
    ((pass++)) || true
else
    echo "FAIL: P9b: gh issue close targeted wrong issue (got: $(cat "$_tmp_p9/captured_close_number"), expected 999)"
    ((fail++)) || true
fi
rm -rf "$_tmp_p9"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
