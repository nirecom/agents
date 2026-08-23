# tests/bin-concern-ledger-input-validation/format-and-producer.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# 4. The format column. It reaches the same names, so it inherits the same
#    surface — but unlike the session ID it has a declared allowlist upstream,
#    and that allowlist is what actually closes the hole.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 4: the format column ---"

{
    new_box
    RC="$(stage_with sess "../escaped" prod)"
    # The session ID is the first component of the derived name, so only it can
    # start a path. A '..' in the format lands mid-name and names a directory
    # nobody created — which makes this the silent-loss failure rather than the
    # traversal one: the round is dropped and the CLI still reports success.
    assert_eq "4: a separator-bearing format is rejected rather than losing the round" \
        "verdict=rejected concern-on-disk=no" \
        "verdict=$(rejected_or "$RC") concern-on-disk=$(holds_concern)"
    assert_eq "4: and nothing is written outside the plans dir either way" \
        "nowhere" "$(landed)"
}

# The wrapper that the plan formats go through does reject an unknown format,
# so the traversal above is unreachable from that entry point. Pinned here
# because it is the only thing standing in front of the builders.
{
    RC=0
    bash "$AGENTS_ROOT/bin/run-codex-review-loop" --format "../escaped" \
        --session-id sess --plans-dir "$PLANS" --draft-file "$REPORT" \
        --cap 1 --max-extensions 0 --extensions-used 0 --round 1 \
        >/dev/null 2>&1 || RC=$?
    assert_eq "4: the loop wrapper refuses a format outside its allowlist" "4" "$RC"
}

# ---------------------------------------------------------------------------
# 5. The producer column, which is the one an external reviewer's output is
#    closest to. Same surface, and the same '..' behaviour.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 5: the producer column ---"

{
    new_box
    RC="$(stage_with sess review-security-shared "../escaped")"
    # Same shape as the format column: mid-name, so a lost round rather than an
    # escaped one — and lost is the outcome a reviewer never sees.
    assert_eq "5: a separator-bearing producer is rejected rather than losing the round" \
        "verdict=rejected concern-on-disk=no" \
        "verdict=$(rejected_or "$RC") concern-on-disk=$(holds_concern)"
    assert_eq "5: and nothing is written outside the plans dir either way" \
        "nowhere" "$(landed)"
}

{
    new_box
    RC="$(stage_with sess review-security-shared "prod name")"
    assert_eq "5: an ordinary producer name with a space still stages" \
        "rc=0 landed=in-plans concern=yes" \
        "rc=$RC landed=$(landed) concern=$(holds_concern)"
}

# ---------------------------------------------------------------------------
# 6. The producer names are a closed set declared in the library, so the
#    producer column is not in fact reviewer-controlled today. Pinned so that a
#    future producer derived from reviewer output is a visible change.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 6: the declared producer set ---"

DECL="$(grep -c 'cl_declared_producers' "$LIB" "$AGENTS_ROOT/bin/lib/concern-ledger/core.sh" 2>/dev/null \
    | awk -F: '{s += $2} END {print s + 0}')"
assert_eq "6: the declared-producer helper still exists" \
    "yes" "$([ "${DECL:-0}" -gt 0 ] && printf yes || printf no)"

PRODUCERS="$(bash -c 'set +u; source "$1" >/dev/null 2>&1 || exit 127; cl_declared_producers review-security-shared' \
    _ "$LIB" 2>/dev/null | tr '\n' ' ')"
PRODUCERS="${PRODUCERS%"${PRODUCERS##*[![:space:]]}"}"
assert_eq_nz "6: the shared code-review format declares its two producers" \
    "review-code-codex security-scanner" "$PRODUCERS"

