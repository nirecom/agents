# tests/bin-concern-ledger-input-validation/format-and-producer.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# 4. The format column reaches the same names as the session ID, but unlike it
#    has a declared allowlist upstream, which is what actually closes the hole.
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
    # The producer reaches the delta's file name, so #2025 C9's fail-closed
    # allowlist covers it exactly as it covers the session ID (CPR-ORTH): a
    # space is outside [A-Za-z0-9._-] and is refused, not filed. The declared
    # producer set below holds no such name, so this narrows nothing in use.
    assert_eq "5: a producer name with a space is refused before anything is written" \
        "refused=yes landed=nowhere concern=no" \
        "refused=$([ "$RC" -ne 0 ] && printf yes || printf no) landed=$(landed) concern=$(holds_concern)"
}

echo ""
echo "--- input 5b: the same tokens, reaching the library directly ---"

# 5b. Every case so far goes through bin/concern-ledger, so all would still
#     pass if the refusal lived only in the CLI's argument parsing. cl_stage
#     builds the delta name itself and is reachable by any caller without the
#     CLI, so the refusal must live where the name is built (#2025 C4, CPR-E2C).

# stage_direct <prefix> <format> <round> <producer> — cl_stage in a subshell
# over a probe dir of its own. Echoes "rc=<n> files=<n>", so a refusal that
# still wrote something reads differently from a clean one.
stage_direct() {
    local dir="$BOX/direct" rc=0
    rm -rf "$dir"; mkdir -p "$dir"
    CL_STAGE_PREFIX="$1" bash -c 'set +u
        source "$1" >/dev/null 2>&1 || exit 127
        cl_stage "$2" "$3" "$4" "$5" complete anchored ""' \
        _ "$LIB" "$dir" "$2" "$3" "$4" >/dev/null 2>&1 || rc=$?
    printf 'rc=%s files=%s' "$rc" "$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
}

{
    new_box
    ROWS5B=0
    while IFS='~' read -r label prefix fmt round prod want; do
        label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
        prefix="${prefix#"${prefix%%[![:space:]]*}"}"; prefix="${prefix%"${prefix##*[![:space:]]}"}"
        fmt="${fmt#"${fmt%%[![:space:]]*}"}"; fmt="${fmt%"${fmt##*[![:space:]]}"}"
        round="${round#"${round%%[![:space:]]*}"}"; round="${round%"${round##*[![:space:]]}"}"
        prod="${prod#"${prod%%[![:space:]]*}"}"; prod="${prod%"${prod##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        [ -z "$label" ] && continue
        case "$label" in \#*) continue ;; esac
        ROWS5B=$((ROWS5B + 1))
        if [ "$want" = "accepted" ]; then
            assert_eq "5b: $label stages one delta" \
                "rc=0 files=1" "$(stage_direct "$prefix" "$fmt" "$round" "$prod")"
        else
            assert_eq "5b: $label is refused with nothing written" \
                "rc=2 files=0" "$(stage_direct "$prefix" "$fmt" "$round" "$prod")"
        fi
    done <<'TABLE'
a well-formed session prefix   ~ sess5b-   ~ review-security-shared ~ 1     ~ review-code-codex     ~ accepted
no session prefix at all       ~           ~ review-security-shared ~ 1     ~ review-code-codex     ~ accepted
a '..' format                  ~ sess5b-   ~ ../escaped             ~ 1     ~ review-code-codex     ~ rejected
a '..' producer                ~ sess5b-   ~ review-security-shared ~ 1     ~ ../escaped            ~ rejected
a '..' round                   ~ sess5b-   ~ review-security-shared ~ ../1  ~ review-code-codex     ~ rejected
a '..' session prefix          ~ ../       ~ review-security-shared ~ 1     ~ review-code-codex     ~ rejected
a separator in the prefix      ~ sub/sess- ~ review-security-shared ~ 1     ~ review-code-codex     ~ rejected
an absolute session prefix     ~ /abs/x-   ~ review-security-shared ~ 1     ~ review-code-codex     ~ rejected
a metacharacter producer       ~ sess5b-   ~ review-security-shared ~ 1     ~ a;touch PWNED-direct  ~ rejected
a glob format                  ~ sess5b-   ~ *                      ~ 1     ~ review-code-codex     ~ rejected
an option-shaped producer      ~ sess5b-   ~ review-security-shared ~ 1     ~ -rf                   ~ rejected
an empty format                ~ sess5b-   ~                        ~ 1     ~ review-code-codex     ~ rejected
TABLE

    assert_eq_nz "5b: every row of the direct-call table ran" "12" "$ROWS5B"
    assert_eq "5b: and no metacharacter in any of them reached a shell" \
        "canaries=0" "canaries=$(canaries)"
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

