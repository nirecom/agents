# tests/bin-concern-ledger-finalize/corrupted-json.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh
# Tags: concern-ledger, finalize, check-finalized, corrupted-artifact, fail-closed, TL2, scope:common
# Sourced by tests/bin-concern-ledger-finalize.sh.

# check-finalized is the gate the loop trusts before it lets a round end: a
# 'yes' here means the unresolved concerns were captured and the round may
# close. cl_artifact_ok reads that verdict off three surface features — the
# schema string, a non-empty file, and the two-line eof terminator — so an
# artifact that is schema-shaped on the outside and broken inside is the case
# that decides whether the gate is fail-CLOSED or merely fail-plausible.

echo ""
echo "--- finalize 9: corrupted but schema-shaped artifacts ---"

CJ_FMT="detail-plan"

# cj_write <file> — the artifact body arrives on stdin.
cj_write() { cat > "$1"; }

# cj_check [<round>] — run check-finalized over this env's artifact, echo
# 'accepted' or 'rejected'. Never echoes the raw rc, so a crash (rc 2) is not
# silently read as a rejection.
cj_check() {
    local rc=0
    if [ -n "${1:-}" ]; then
        bash "$CLI" check-finalized --plans-dir "$PLANS" --session-id "$SID" \
            --format "$CJ_FMT" --round "$1" >/dev/null 2>&1 || rc=$?
    else
        bash "$CLI" check-finalized --plans-dir "$PLANS" --session-id "$SID" \
            --format "$CJ_FMT" >/dev/null 2>&1 || rc=$?
    fi
    case "$rc" in
        0) printf 'accepted' ;;
        1) printf 'rejected' ;;
        *) printf 'crashed-rc%s' "$rc" ;;
    esac
}

# cj_parses <file> — 'yes' / 'no' from a real JSON parser, or 'no-parser'.
cj_parses() {
    if command -v node >/dev/null 2>&1; then
        if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' \
            "$1" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
        return
    fi
    if command -v jq >/dev/null 2>&1; then
        if jq . "$1" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
        return
    fi
    printf 'no-parser'
}

# ---------------------------------------------------------------------------
# 9a. The positive control. A real finalize must produce an artifact that both
#     the gate and a real JSON parser accept — otherwise every rejection below
#     is satisfied by a gate that rejects everything.
# ---------------------------------------------------------------------------
{
    new_env
    LED="$(ledger_file "$PLANS" "$SID" "$CJ_FMT")"
    mk_ledger "$LED" "$CJ_FMT" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/lib/concern-ledger/finalize.sh#cl_artifact_ok:security" \
            aa11bb review-code-codex review-code-codex - "$OPEN_TEXT")"
    printf '2\n' > "$(round_file "$PLANS" "$SID" "$CJ_FMT")"
    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$CJ_FMT" \
        --mode terminal --reason "cap reached without convergence" --round 2 \
        --cap 2 --max-extensions 0 --extensions-used 0
    GOOD="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    assert_eq "9a: a real finalize succeeds (precondition)" "0" "$LAST_RC"
    assert_eq "9a: the gate accepts the artifact finalize just wrote" \
        "accepted" "$(cj_check)"
    assert_eq "9a: the gate accepts it for the round it names" \
        "accepted" "$(cj_check 2)"
    PARSES="$(cj_parses "$GOOD")"
    if [ "$PARSES" = "no-parser" ]; then
        fail "9a: no JSON parser on PATH — the validity contrast below is unverifiable"
    else
        assert_eq "9a: a real JSON parser also accepts it" "yes" "$PARSES"
    fi
    # Keep the good bytes: the corruption cases below are edits of this exact
    # artifact, so any rejection is attributable to the edit and nothing else.
    CJ_GOOD_BYTES="$TMPDIR_BASE/cj-good.json"
    cp "$GOOD" "$CJ_GOOD_BYTES"
    CJ_GOOD_ROUND=2
}

# ---------------------------------------------------------------------------
# 9b. Damage the gate does catch. Each row starts from the byte-identical good
#     artifact, so the mutation is the only difference.
# ---------------------------------------------------------------------------
{
    # cj_mutate <label> <want> <sed-program>
    cj_mutate() {
        new_env
        local out
        out="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
        sed "$3" "$CJ_GOOD_BYTES" > "$out"
        assert_eq "9b: $1" "$2" "$(cj_check)"
    }

    cj_mutate "the schema line removed is rejected" "rejected" '/"schema":/d'
    cj_mutate "the eof terminator removed is rejected" "rejected" '/"eof":/d'
    cj_mutate "the eof key renamed is rejected" "rejected" 's/"eof":/"eofx":/'

    # Truncation: everything from the concerns array onward is lost, which is
    # exactly what a killed writer leaves behind.
    new_env
    TRUNC="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    sed -n '1,3p' "$CJ_GOOD_BYTES" > "$TRUNC"
    assert_eq "9b: a truncated artifact is rejected" "rejected" "$(cj_check)"

    # Trailing bytes after the terminator: the eof line is present but no longer
    # last, so whatever follows was never covered by the writer's contract.
    new_env
    TRAIL="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    cp "$CJ_GOOD_BYTES" "$TRAIL"
    printf '{"appended": "by something else"}\n' >> "$TRAIL"
    assert_eq "9b: bytes appended after the terminator are rejected" \
        "rejected" "$(cj_check)"

    new_env
    EMPTY="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    : > "$EMPTY"
    assert_eq "9b: a zero-length artifact is rejected" "rejected" "$(cj_check)"

    new_env
    assert_eq "9b: a missing artifact is rejected" "rejected" "$(cj_check)"

    # A directory squatting on the artifact path: nothing can be read from it,
    # and the gate must not read 'the path exists' as 'the round finalized'.
    new_env
    mkdir -p "$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    assert_eq "9b: a directory on the artifact path is rejected" \
        "rejected" "$(cj_check)"

    # Round binding: a good artifact from an earlier round must not answer for
    # a later one.
    new_env
    OLDR="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    cp "$CJ_GOOD_BYTES" "$OLDR"
    assert_eq "9b: an artifact from round $CJ_GOOD_ROUND is rejected for round 3" \
        "rejected" "$(cj_check 3)"
    assert_eq "9b: and still accepted for the round it names" \
        "accepted" "$(cj_check "$CJ_GOOD_ROUND")"
}

# ---------------------------------------------------------------------------
# 9c. Damage the gate must catch and does not. cl_artifact_ok is jq-free — the
#     writer has no JSON parser to lean on — so the interior is unchecked.

#     The requirement asserted below is the one the gate's own name states: an
#     artifact a real JSON parser rejects is not a finalized artifact, so the
#     gate must reject it too. Every row pairs the gate's verdict with the
#     parser's, which is what makes a rejection a real one rather than a gate
#     that refuses everything. Without a parser on PATH the row fails.
# ---------------------------------------------------------------------------
{
    # cj_corrupt <label> <sed-program> — a real parser must refuse the mutated
    # file, and so must the gate.
    cj_corrupt() {
        new_env
        local out
        out="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
        sed "$2" "$CJ_GOOD_BYTES" > "$out"
        local parses
        parses="$(cj_parses "$out")"
        if [ "$parses" = "no-parser" ]; then
            fail "9c: $1 — no JSON parser on PATH to confirm the file is broken"
            return
        fi
        assert_eq "9c: $1 — a real parser refuses it (precondition)" "no" "$parses"
        xfail_eq "9c: $1 — the gate must refuse it too" "rejected" "$(cj_check)"
    }

    cj_corrupt "an unterminated string inside the body" \
        's/"converged"/"conv\\erged" ,,, "x/'
    cj_corrupt "a stray comma sequence inside the body" \
        's/"round"/,,,"round"/'
    cj_corrupt "an unbalanced closing brace" 's/"concerns"/}}}"concerns"/'
    cj_corrupt "a raw control character inside a string value" \
        's/"converged"/"conv\x01erged"/'
    cj_corrupt "a single-quoted key, which is JavaScript and not JSON" \
        "s/\"converged\"/'converged'/"

    # The strongest form: nothing of the real artifact survives except the three
    # surface features the gate looks at. A file an attacker (or a half-written
    # unrelated tool) could produce byte-for-byte without ever running finalize.
    new_env
    FORGED="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    cj_write "$FORGED" <<'FORGED_EOF'
{
  "schema": "unresolved-concerns/v1",
  "round": 2,
  this line is not JSON at all, and neither is the next one:
  <<<<<<< nothing here parses >>>>>>>
  "eof": "unresolved-concerns/v1-end"
}
FORGED_EOF
    FORGED_PARSES="$(cj_parses "$FORGED")"
    if [ "$FORGED_PARSES" = "no-parser" ]; then
        fail "9c: no JSON parser on PATH to confirm the forged artifact is broken"
    else
        assert_eq "9c: the forged artifact is unreadable to a real parser (precondition)" \
            "no" "$FORGED_PARSES"
        xfail_eq "9c: a hand-forged artifact carrying only the three surface markers is rejected" \
            "rejected" "$(cj_check)"
        xfail_eq "9c: and it is rejected for the round it claims" \
            "rejected" "$(cj_check 2)"
    fi

    # The round check is a literal substring match, so the question is whether a
    # concern's own prose can spoof it. It cannot: prose reaches the artifact
    # JSON-escaped, and `\"round\": 9,` does not contain the literal the check
    # looks for. Pinned because the escaping is what holds the line here.
    new_env
    SPOOF="$(json_file "$PLANS" "$SID" "$CJ_FMT")"
    cj_write "$SPOOF" <<'SPOOF_EOF'
{
  "schema": "unresolved-concerns/v1",
  "round": 1,
  "concerns": [
    { "id": "C1", "text": "the reviewer wrote \"round\": 9, in their finding" }
  ],
  "eof": "unresolved-concerns/v1-end"
}
SPOOF_EOF
    assert_eq "9c: an escaped round number inside a concern's prose does not spoof the round check" \
        "rejected" "$(cj_check 9)"
    assert_eq "9c: the artifact's own round still satisfies the round check" \
        "accepted" "$(cj_check 1)"
    assert_eq "9c: a round claimed nowhere in the file is still rejected" \
        "rejected" "$(cj_check 4)"
}
