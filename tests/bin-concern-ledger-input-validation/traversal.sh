# tests/bin-concern-ledger-input-validation/traversal.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# 3. Traversal. This is the failure the plans dir exists to prevent: a session
#    ID carrying a separator makes the derived name a path, and the round's
#    bytes leave the directory the caller nominated.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 3: separators in a derived name ---"

# rejected_or <rc> — 'rejected' when the CLI refused, 'accepted' when it claimed
# success. The rc alone, named rather than numbered, so a row reads as a verdict.
rejected_or() { [ "$1" -ne 0 ] && printf 'rejected' || printf 'accepted'; }

{
    new_box
    RC="$(stage_with "../escaped" review-security-shared prod)"
    # Required behaviour: a separator in a derived name must be refused before
    # any filesystem mutation. Nothing may be written outside the plans dir the
    # caller nominated, and the refusal must carry a non-zero exit.
    xfail_eq "3: a '..' session ID is rejected before it can write anywhere" \
        "verdict=rejected landed=nowhere" \
        "verdict=$(rejected_or "$RC") landed=$(landed)"
}

{
    new_box
    RC="$(stage_with "sub/nested" review-security-shared prod)"
    assert_eq "3: a '/' session ID fails closed when its parent directory does not exist" \
        "rc=5 landed=nowhere concern=no" \
        "rc=$RC landed=$(landed) concern=$(holds_concern)"
}

# The absolute-path form is the silent-loss case, and it is worse than the
# traversal: the CLI reports success while the round's findings reach no file at
# all. Composite so that "nothing was written" cannot pass on its own — the rc
# is what makes it a loss rather than a rejection.
{
    new_box
    ABS="$TMPDIR_BASE/absolute-target"
    RC="$(stage_with "$ABS" review-security-shared prod)"
    # Required behaviour: success is a claim that the round reached disk. When
    # the delta destination cannot be written the CLI must not make that claim.
    assert_eq "3: an absolute session ID is rejected rather than silently losing the round" \
        "verdict=rejected concern-on-disk=no" \
        "verdict=$(rejected_or "$RC") concern-on-disk=$(holds_concern)"
    assert_eq "3: and in no case does it write outside the plans dir" \
        "nowhere" "$(landed)"
}

# The same three inputs feed every path the ledger owns, so a separator that
# escapes in one escapes in all of them (CPR-ORTH). Asserted over the builders
# themselves rather than one subcommand's behaviour.
{
    PROBE="$TMPDIR_BASE/paths.sh"
    cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set +u
source "$1" >/dev/null 2>&1 || exit 127
# The builders print without a trailing newline, so one line per path here.
printf '%s\n' "$(cl_ledger_path   "$2" "$3" f)"
printf '%s\n' "$(cl_snapshot_path "$2" "$3" f)"
printf '%s\n' "$(cl_json_path     "$2" "$3" f)"
printf '%s\n' "$(cl_diag_path     "$2" "$3" f)"
printf '%s\n' "$(cl_round_path    "$2" "$3" f)"
printf '%s\n' "$(cl_delta_path    "$2" "$3" f 1 p)"
PROBE_EOF
    ESCAPING=0
    TOTAL=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        TOTAL=$((TOTAL + 1))
        case "$line" in */plansdir/../*) ESCAPING=$((ESCAPING + 1)) ;; esac
    done < <(bash "$PROBE" "$LIB" /plansdir "../escaped" 2>/dev/null)
    assert_eq_nz "3: every path builder was probed" "6" "$TOTAL"
    # Required behaviour: no builder may emit a path that leaves the plans dir.
    # The count is over all six, so a fix to one of them is not enough (CPR-ORTH).
    xfail_eq "3: no path builder lets a '..' escape the plans dir" "0" "$ESCAPING"
}

# ---------------------------------------------------------------------------
