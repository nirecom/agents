# tests/bin-concern-ledger-finalize/atomic-failclosed.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/run-codex-review-loop, skills/review-code-security/scripts/close-concern-round.sh
# Tags: concern-ledger, finalize, fail-closed, atomic-write, TL2, scope:common
# Sourced by tests/bin-concern-ledger-finalize.sh.
# Detail-plan cases 5, 6(a)-(d), 7: atomic replacement, fail-CLOSED termination,
# read-only artifact verdict. Portable fault injections: `awk` shadowed on PATH
# (serialization failure), directory at the artifact path (unwritable dest;
# `chmod 555` is a no-op on Windows, so not usable — CPR-UNV).

echo ""
echo "--- finalize 5/6/7: atomic replacement, fail-CLOSED, artifact verdict ---"

FIN_FMT="review-security-shared"

# fin_seed — a live ledger with one open entry plus round-2 staging.
fin_seed() {
    local led
    led="$(ledger_file "$PLANS" "$SID" "$FIN_FMT")"
    mk_ledger "$led" "$FIN_FMT" "$SID" 1 \
        "$(row C1 HIGH open 1 2 "bin/lib/concern-ledger.sh#cl_write_json:correctness" \
            d1a2b3 review-code-codex review-code-codex - "$OPEN_TEXT")"
    mk_staging "$(delta_file "$PLANS" "$SID" "$FIN_FMT" 2 review-code-codex)" \
        review-code-codex COMPLETE PERFORMED COMPLETE 2
    printf '2\n' > "$(round_file "$PLANS" "$SID" "$FIN_FMT")"
}

# fin_run <mode> — finalize at round 2 with the standard budget arguments.
fin_run() {
    run_cli finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FIN_FMT" \
        --mode "$1" --reason "cap reached without convergence" --round 2 \
        --cap 2 --max-extensions 0 --extensions-used 0
}

# fin_run_path <PATH> <mode> — the same, under an injected PATH.
fin_run_path() {
    local p="$1" mode="$2"
    run_cli_path "$p" finalize --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FIN_FMT" --mode "$mode" --reason "cap reached without convergence" \
        --round 2 --cap 2 --max-extensions 0 --extensions-used 0
}

# An awk that dies partway through emitting a body.
AWK_PARTIAL="$(shadow_dir awk 'printf "{\n  \"schema\": \"unresolved-concerns/v1\",\n  \"converged\": false,\n"
exit 1')"
# An awk that succeeds but never writes the terminator.
AWK_NO_EOF="$(shadow_dir awk 'printf "{\n  \"schema\": \"unresolved-concerns/v1\",\n  \"converged\": false,\n  \"concerns\": []\n}\n"
exit 0')"

# ---------------------------------------------------------------------------
# 5(a). The success path leaves no temporary file behind.
# ---------------------------------------------------------------------------
{
    new_env
    fin_seed
    fin_run terminal
    assert_eq "5a: the baseline finalize succeeds" "0" "$LAST_RC"
    assert_eq "5a: the success path writes the artifact and leaves no tmp behind" \
        "artifact=present residue=0" \
        "artifact=$(file_state "$(json_file "$PLANS" "$SID" "$FIN_FMT")") residue=$(tmp_residue "$PLANS")"
}

# ---------------------------------------------------------------------------
# 5(b)/(c). A serialization failure over an existing artifact: the good artifact
# must survive untouched, the tmp must be removed, and finalize must report 5.
# ---------------------------------------------------------------------------
{
    new_env
    fin_seed
    JSON_PATH="$(json_file "$PLANS" "$SID" "$FIN_FMT")"
    fin_run terminal
    assert_eq "5b: the first finalize succeeds (precondition)" "0" "$LAST_RC"
    GOOD="$(fingerprint "$JSON_PATH")"

    fin_run_path "$AWK_PARTIAL:$PATH" terminal
    assert_eq "5b/5c: the good artifact survives, the tmp goes, the code says 5" \
        "dest=present-and-unchanged residue=0 rc=5" \
        "dest=$(intact_state "$JSON_PATH" "$GOOD") residue=$(tmp_residue "$PLANS") rc=$LAST_RC"
}

# 5(b), the no-previous-artifact half: absence must stay absence.
{
    new_env
    fin_seed
    JSON_PATH="$(json_file "$PLANS" "$SID" "$FIN_FMT")"
    fin_run_path "$AWK_PARTIAL:$PATH" terminal
    assert_eq "5b/5c: with no previous artifact, absence stays absence at code 5" \
        "dest=missing residue=0 rc=5" \
        "dest=$(file_state "$JSON_PATH") residue=$(tmp_residue "$PLANS") rc=$LAST_RC"
}

# ---------------------------------------------------------------------------
# 5(d). Serialization that *succeeds* but omits the terminator — the direct pin
# on the self-verification step, which is the only thing that can catch it.
# ---------------------------------------------------------------------------
{
    new_env
    fin_seed
    JSON_PATH="$(json_file "$PLANS" "$SID" "$FIN_FMT")"
    fin_run_path "$AWK_NO_EOF:$PATH" terminal
    assert_eq "5d: a terminator-less tmp is rejected, removed, and reported as 5" \
        "dest=missing residue=0 rc=5" \
        "dest=$(file_state "$JSON_PATH") residue=$(tmp_residue "$PLANS") rc=$LAST_RC"
}

# ---------------------------------------------------------------------------
# 6(a)-(d). The destination cannot be written at all.
# ---------------------------------------------------------------------------
{
    new_env
    fin_seed
    LED="$(ledger_file "$PLANS" "$SID" "$FIN_FMT")"
    JSON_PATH="$(json_file "$PLANS" "$SID" "$FIN_FMT")"
    DIAG_PATH="$(diag_file "$PLANS" "$SID" "$FIN_FMT")"
    BEFORE="$(fingerprint "$LED")"
    # Both the artifact path and the diagnostic path are occupied by directories:
    # nothing about the outcome may depend on being able to write a diagnostic.
    mkdir -p "$JSON_PATH" "$DIAG_PATH"

    fin_run escalate
    ERRTEXT="$(last_err)"

    # Composite: a run that died before touching anything would otherwise satisfy
    # "the ledger was kept" without ever having reached the escalate branch.
    assert_eq "6a/6b: escalate fails closed at code 5 and keeps the live ledger" \
        "rc=5 ledger=present-and-unchanged" \
        "rc=$LAST_RC ledger=$(intact_state "$LED" "$BEFORE")"
    assert_contains "6c: the failure is announced on stdout" \
        "## Concern Ledger: FINALIZE-FAILED — " "$LAST_OUT"
    assert_contains "6c: the failure is announced on stderr too" \
        "## Concern Ledger: FINALIZE-FAILED — " "$ERRTEXT"
    assert_not_contains "6c: stdout is the durable report channel — no absolute host path there" \
        "(recovered copy: " "$LAST_OUT"
    assert_contains "6c: the recovered copy is named on stderr instead" \
        "(recovered copy: " "$ERRTEXT"

    RECOVERED="$(printf '%s\n' "$ERRTEXT" | sed -n 's/.*(recovered copy: \([^)]*\)).*/\1/p' | head -n 1)"
    assert_match "6c: the recovered copy is given as an absolute path" \
        '^(/|[A-Za-z]:)' "$RECOVERED"
    assert_contains "6c: the recovered copy carries the unresolved concern" \
        "$OPEN_TEXT" "$(json_of "$RECOVERED")"
    assert_eq "6c: the copy exists on the side path and is never moved onto the destination" \
        "recovered=present destination=not-a-file" \
        "recovered=$(file_state "$RECOVERED") destination=$(file_state "$JSON_PATH")"

    assert_eq "6d: check-finalized fails even with no writable diagnostic" \
        "1" "$(rc_of check-finalized --plans-dir "$PLANS" --session-id "$SID" \
                --format "$FIN_FMT" --round 2)"
}

# ---------------------------------------------------------------------------
# 7. check-finalized is a read-only verdict over five ways an artifact can be
#    wrong, plus the one way it can be right.
# ---------------------------------------------------------------------------
{
    new_env
    fin_seed
    JSON_PATH="$(json_file "$PLANS" "$SID" "$FIN_FMT")"
    fin_run terminal
    assert_eq "7: the reference artifact is produced (precondition)" "0" "$LAST_RC"
    VALID="$TMPDIR_BASE/valid-artifact.json"
    cp "$JSON_PATH" "$VALID" 2>/dev/null || : > "$VALID"

    while IFS='|' read -r mutation want; do
        mutation="$(trim "$mutation")"; want="$(trim "$want")"
        [ -z "$mutation" ] && continue
        case "$mutation" in \#*) continue ;; esac

        rm -rf "$JSON_PATH"
        case "$mutation" in
            intact)
                cp "$VALID" "$JSON_PATH" 2>/dev/null || true ;;
            absent)
                : ;;
            zero-bytes)
                : > "$JSON_PATH" ;;
            schema-missing)
                sed 's|unresolved-concerns/v1"|some-other-schema/v9"|' "$VALID" \
                    > "$JSON_PATH" 2>/dev/null || true ;;
            round-mismatch)
                sed 's|"round": 2|"round": 1|' "$VALID" > "$JSON_PATH" 2>/dev/null || true ;;
            terminator-missing)
                # A complete-looking file whose last two lines were lopped off —
                # the shape a hand-restored recovery copy can have.
                # (`head -n -2` is GNU-only; count and slice instead.)
                VTOTAL="$(wc -l < "$VALID" 2>/dev/null || printf 0)"
                VKEEP=$(( VTOTAL - 2 )); [ "$VKEEP" -lt 0 ] && VKEEP=0
                sed -n "1,${VKEEP}p" "$VALID" > "$JSON_PATH" 2>/dev/null || true ;;
            *)
                fail "7: unknown mutation token '$mutation'"; continue ;;
        esac

        assert_eq "7: $mutation" "$want" \
            "$(rc_of check-finalized --plans-dir "$PLANS" --session-id "$SID" \
                --format "$FIN_FMT" --round 2)"
    done <<'TABLE'
intact             | 0
absent             | 1
zero-bytes         | 1
schema-missing     | 1
round-mismatch     | 1
terminator-missing | 1
TABLE

    # The verdict must never repair or rewrite what it inspected.
    rm -rf "$JSON_PATH"
    cp "$VALID" "$JSON_PATH" 2>/dev/null || true
    BEFORE="$(fingerprint "$JSON_PATH")"
    VERDICT_RC="$(rc_of check-finalized --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FIN_FMT" --round 2)"
    assert_eq "7: the verdict is read-only — it inspects without rewriting" \
        "rc=0 artifact=present-and-unchanged" \
        "rc=$VERDICT_RC artifact=$(intact_state "$JSON_PATH" "$BEFORE")"
}
