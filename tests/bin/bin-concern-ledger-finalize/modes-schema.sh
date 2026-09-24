# tests/bin-concern-ledger-finalize/modes-schema.sh
# lang-check: ignore -- table below deliberately asserts non-ASCII survives verbatim
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh
# Tags: concern-ledger, finalize, modes, json-schema, serialization, TL2, scope:common
# Sourced by tests/bin-concern-ledger-finalize.sh.
# Detail-plan Test plan (finalize TL2) cases 1, 2, 3, 4 — the two modes, the
# artifact schema, and the jq-free serialization.

echo ""
echo "--- finalize 1/2/3/4: modes, JSON schema, serialization sanity ---"

# seed_ledger <format> — a live ledger carrying one open entry, one resolved
# entry, one unparsed line and one merged alternate, plus round-2 staging for
# two producers. Echoes nothing; the caller reads $PLANS / $SID.
seed_ledger() {
    local fmt="$1" led
    led="$(ledger_file "$PLANS" "$SID" "$fmt")"
    mk_ledger "$led" "$fmt" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/lib/concern-ledger.sh#cl_write_json:correctness" \
            d1a2b3 review-code-codex review-code-codex - "$OPEN_TEXT")" \
        "$(row C2 MEDIUM resolved 1 2 "bin/concern-ledger#finalize:correctness" \
            e4f5a6 security-scanner security-scanner - "$DONE_TEXT")" \
        "#unparsed|- [HIGH] a bullet the reviewer mangled beyond parsing" \
        "#merged-alt|C1|the same concern in the second producer's wording"
    mk_staging "$(delta_file "$PLANS" "$SID" "$fmt" 2 review-code-codex)" \
        review-code-codex COMPLETE PERFORMED COMPLETE 2
    mk_staging "$(delta_file "$PLANS" "$SID" "$fmt" 2 security-scanner)" \
        security-scanner PARTIAL PERFORMED PARTIAL 2
    printf '2\n' > "$(round_file "$PLANS" "$SID" "$fmt")"
}

# ---------------------------------------------------------------------------
# 1. --mode escalate — the cap snapshot lands on the path the two planner
#    SKILL.md files reference literally, and the live ledger is removed.
# ---------------------------------------------------------------------------
{
    FMT="detail-plan"
    new_env
    seed_ledger "$FMT"
    LED="$(ledger_file "$PLANS" "$SID" "$FMT")"
    SNAP="$(snapshot_file "$PLANS" "$SID" "$FMT")"
    BEFORE="$(fingerprint "$LED")"

    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode escalate --reason "risk-signal at ceiling" --round 2 \
        --cap 2 --max-extensions 1 --extensions-used 1

    assert_eq "1: escalate finalize succeeds" "0" "$LAST_RC"
    assert_eq "1: the cap snapshot is written" "present" "$(file_state "$SNAP")"
    assert_eq "1: the snapshot path is the one make-detail-plan documents" \
        "$PLANS/$SID-detail-plan-concern-ledger-cap-snapshot.txt" "$SNAP"
    assert_eq_nz "1: the snapshot is a byte copy of the live ledger" \
        "$BEFORE" "$(fingerprint "$SNAP")"
    assert_eq "1: escalate removes the live ledger" "missing" "$(file_state "$LED")"
    assert_eq "1: the unresolved-concerns artifact is written too" \
        "present" "$(file_state "$(json_file "$PLANS" "$SID" "$FMT")")"

    # The literal in the consuming skill is the SSOT for this path — if it is
    # reworded, the assertion above stops describing reality.
    assert_contains "1: make-detail-plan still documents the same literal path" \
        "-detail-plan-concern-ledger-cap-snapshot.txt" \
        "$(cat "$AGENTS_ROOT/skills/make-detail-plan/SKILL.md" 2>/dev/null || true)"
    assert_contains "1: make-outline-plan still documents the same literal path" \
        "-outline-plan-concern-ledger-cap-snapshot.txt" \
        "$(cat "$AGENTS_ROOT/skills/make-outline-plan/SKILL.md" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# 2. --mode terminal — purely additive: the JSON appears, nothing is taken away.
# ---------------------------------------------------------------------------
{
    FMT="test-review"
    new_env
    seed_ledger "$FMT"
    LED="$(ledger_file "$PLANS" "$SID" "$FMT")"
    BEFORE="$(fingerprint "$LED")"

    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode terminal --reason "cap reached without convergence" --round 2 \
        --cap 1 --max-extensions 0 --extensions-used 0

    assert_eq "2: terminal finalize succeeds" "0" "$LAST_RC"
    # One composite value: a finalize that never ran would satisfy "the ledger
    # survived" and "no snapshot was written" for the wrong reason.
    assert_eq "2: terminal adds the artifact and takes nothing away" \
        "artifact=present ledger=present-and-unchanged snapshot=missing" \
        "artifact=$(file_state "$(json_file "$PLANS" "$SID" "$FMT")") ledger=$(intact_state "$LED" "$BEFORE") snapshot=$(file_state "$(snapshot_file "$PLANS" "$SID" "$FMT")")"
}

# ---------------------------------------------------------------------------
# 3. The artifact schema — every field a consumer is promised, plus the rule
#    that only open entries reach concerns[].
# ---------------------------------------------------------------------------
{
    FMT="review-security-shared"
    new_env
    seed_ledger "$FMT"
    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode terminal --reason "cap reached without convergence" --round 2 \
        --cap 2 --max-extensions 1 --extensions-used 1
    assert_eq "3: the finalize under test succeeds (precondition)" "0" "$LAST_RC"
    JSON="$(json_of "$(json_file "$PLANS" "$SID" "$FMT")")"

    while IFS='|' read -r label needle; do
        label="$(trim "$label")"; needle="$(trim "$needle")"
        [ -z "$label" ] && continue
        case "$label" in \#*) continue ;; esac
        assert_contains "3: $label" "$needle" "$JSON"
    done <<'TABLE'
schema identifier            | "schema": "unresolved-concerns/v1"
convergence flag             | "converged": false
termination reason           | "reason": "cap reached without convergence"
termination round            | "round": 2
termination cap              | "cap": 2
termination extensions_used  | "extensions_used": 1
producers array              | "producers"
producer completeness field  | "completeness"
producer exec_label field    | "exec_label"
producer parse_label field   | "parse_label"
first producer name          | review-code-codex
second producer name         | security-scanner
counts object                | "counts"
concerns array               | "concerns"
unparsed array               | "unparsed"
merged alternates array      | "merged_alternates"
terminator member            | "eof": "unresolved-concerns/v1-end"
TABLE

    # Composite again: an empty artifact must not read as "resolved entries were
    # correctly excluded".
    OPEN_IN=absent; printf '%s' "$JSON" | grep -Fq -- "$OPEN_TEXT" && OPEN_IN=present
    DONE_IN=absent; printf '%s' "$JSON" | grep -Fq -- "$DONE_TEXT" && DONE_IN=present
    assert_eq "3: concerns[] carries the open entry and only the open entry" \
        "open=present resolved=absent" "open=$OPEN_IN resolved=$DONE_IN"
    assert_contains "3: the unparsed reviewer line is carried over" \
        "a bullet the reviewer mangled beyond parsing" "$JSON"
    assert_contains "3: the merged alternate body is carried over" \
        "the same concern in the second producer's wording" "$JSON"
    assert_eq "3: termination is nested under a termination object" \
        "yes" "$(printf '%s' "$JSON" | grep -Fq '"termination"' && printf yes || printf no)"
}

# ---------------------------------------------------------------------------
# 4. Serialization sanity — the awk serializer must survive a hostile body, and
#    jq must be optional rather than required.
# ---------------------------------------------------------------------------
{
    FMT="review-security-shared"
    new_env
    LED="$(ledger_file "$PLANS" "$SID" "$FMT")"
    mk_ledger "$LED" "$FMT" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/lib/concern-ledger.sh#cl_write_json:correctness" \
            9f8e7d review-code-codex review-code-codex - "$NASTY_TEXT")"
    mk_staging "$(delta_file "$PLANS" "$SID" "$FMT" 2 review-code-codex)" \
        review-code-codex COMPLETE PERFORMED COMPLETE 2
    printf '2\n' > "$(round_file "$PLANS" "$SID" "$FMT")"

    JSON_PATH="$(json_file "$PLANS" "$SID" "$FMT")"
    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode terminal --reason "cap reached" --round 2 \
        --cap 2 --max-extensions 0 --extensions-used 0
    assert_eq "4: a hostile concern body does not break finalize" "0" "$LAST_RC"
    assert_eq "4: the artifact is written despite the hostile body" \
        "present" "$(file_state "$JSON_PATH")"
    JSON="$(json_of "$JSON_PATH")"

    # '~' is the column separator here: one of the expected needles is itself a
    # '|', the very byte the ledger uses as its field separator.
    while IFS='~' read -r label needle; do
        label="$(trim "$label")"; needle="$(trim "$needle")"
        [ -z "$label" ] && continue
        case "$label" in \#*) continue ;; esac
        assert_contains "4: $label" "$needle" "$JSON"
    done <<'TABLE'
double quote is escaped      ~ \"quoted\"
backslash is escaped         ~ \\backslash
tab is escaped               ~ \ttab
control char becomes \uXXXX  ~ \u0001
non-ASCII survives verbatim  ~ 日本語
the field separator is data  ~ | pipe
TABLE

    # A raw TAB inside the JSON string would be the failure this escaping exists
    # to prevent; the escaped form was asserted above.
    assert_eq "4: no raw TAB survives inside the serialized body" \
        "0" "$(grep -c "$(printf '\t')" "$JSON_PATH" 2>/dev/null || true)"
    assert_eq "4: the last two lines are the fixed terminator form" \
        '  "eof": "unresolved-concerns/v1-end"/}/' "$(tail2 "$JSON_PATH")"

    if [ "$(has_jq)" = "yes" ]; then
        JQ_RC=0
        jq -e . "$JSON_PATH" >/dev/null 2>&1 || JQ_RC=$?
        assert_eq "4: jq -e . accepts the generated artifact" "0" "$JQ_RC"
    else
        echo "NOTE: jq is absent — the 'jq -e .' row could not be evaluated here."
    fi

    # And the same artifact must be produced with jq removed from PATH: jq is a
    # verifier, never a dependency of the write path.
    new_env
    LED2="$(ledger_file "$PLANS" "$SID" "$FMT")"
    mk_ledger "$LED2" "$FMT" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/lib/concern-ledger.sh#cl_write_json:correctness" \
            9f8e7d review-code-codex review-code-codex - "$NASTY_TEXT")"
    mk_staging "$(delta_file "$PLANS" "$SID" "$FMT" 2 review-code-codex)" \
        review-code-codex COMPLETE PERFORMED COMPLETE 2
    printf '2\n' > "$(round_file "$PLANS" "$SID" "$FMT")"
    JSON_NOJQ="$(json_file "$PLANS" "$SID" "$FMT")"
    run_cli_path "$(path_without jq)" finalize --plans-dir "$PLANS" \
        --session-id "$SID" --format "$FMT" --mode terminal --reason "cap reached" \
        --round 2 --cap 2 --max-extensions 0 --extensions-used 0
    assert_eq "4: finalize succeeds with jq off PATH" "0" "$LAST_RC"
    assert_eq "4: the artifact is still produced with jq off PATH" \
        "present" "$(file_state "$JSON_NOJQ")"
    assert_eq "4: the jq-free artifact still ends with the terminator" \
        '  "eof": "unresolved-concerns/v1-end"/}/' "$(tail2 "$JSON_NOJQ")"
    # The escaping is done by the serializer, not by jq — so the hostile body
    # must come out escaped the same way with jq unavailable. (The two artifacts
    # carry different session ids, so they are compared by escaping, not bytes.)
    NOJQ="$(json_of "$JSON_NOJQ")"
    assert_contains "4: the jq-free artifact escapes the double quote" \
        '\"quoted\"' "$NOJQ"
    assert_contains "4: the jq-free artifact escapes the backslash" \
        '\\backslash' "$NOJQ"
    assert_contains "4: the jq-free artifact escapes the tab" '\ttab' "$NOJQ"
    assert_eq "4: the jq-free artifact leaks no raw TAB either" \
        "0" "$(grep -c "$(printf '\t')" "$JSON_NOJQ" 2>/dev/null || true)"
}
