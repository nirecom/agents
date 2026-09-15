# tests/feature-2276-review-code-security-codex/static-contracts.sh
# Tests: bin/lib/codex-review-loop/format-params.sh, bin/lib/concern-ledger/core.sh
# Tags: review-loop, security-code, format-params, closed-producer-set, TL2, scope:issue-specific
#
# Sourced by tests/feature-2276-review-code-security-codex.sh.
# The table row, the extracted parameters, the closed producer set, and the
# files the migration removes — the parts that must hold before any chain runs.

echo ""
echo "--- S: format table, extracted parameters, closed producer set ---"

cl() { ( set +u; . "$CL_LIB" >/dev/null 2>&1 || exit 99; "$@" ); }

# --- the format-params table ------------------------------------------------
FP_TEXT="$(cat "$FMT_PARAMS" 2>/dev/null || true)"
for _tok in "security-code" "review-security-shared" "bin/review-code-codex" \
            "anchored" "input_kind" "ledger_format" "prestaged"; do
    assert_contains "S: format-params.sh declares '$_tok'" "$_tok" "$FP_TEXT"
done
for _fmt in detail-plan outline-plan security-plan test-review; do
    assert_contains "S: format-params.sh keeps the existing format '$_fmt'" "$_fmt" "$FP_TEXT"
done
assert_contains "S: format-params.sh keeps the path-kind reviewer" "bin/review-plan-codex" "$FP_TEXT"

assert_eq "S: the loop sources the extracted format table" \
    "1" "$(grep -c 'codex-review-loop/format-params.sh' "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: the loop no longer hardcodes the format allowlist" \
    "0" "$(grep -c 'detail-plan|outline-plan|security-plan|test-review)' "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: the loop no longer hardcodes review-plan-codex as THE reviewer" \
    "0" "$(grep -c 'REVIEWER="\$AGENTS_CONFIG_DIR/bin/review-plan-codex"' "$LOOP_BIN" 2>/dev/null || true)"

LOOP_LINES="$(wc -l < "$LOOP_BIN" 2>/dev/null | tr -d ' ')"
LOOP_SHRANK=no
[ -n "$LOOP_LINES" ] && [ "$LOOP_LINES" -lt 641 ] && LOOP_SHRANK=yes
assert_eq "S: the loop is smaller after the extraction (was 641 lines)" "yes" "$LOOP_SHRANK"

for _newlib in "$FMT_PARAMS" "$REF_KIND"; do
    _n="$(wc -l < "$_newlib" 2>/dev/null | tr -d ' ')"
    _under=no
    [ -n "$_n" ] && [ "$_n" -lt 300 ] && _under=yes
    assert_eq "S: ${_newlib#"$AGENTS_ROOT/"} stays under the 300-line WARN limit" "yes" "$_under"
done

# --- the ledger-format / round-format split (S8-a) --------------------------
assert_eq "S: the ledger file name is built from LEDGER_FORMAT" \
    "1" "$(grep -c 'SID-\$LEDGER_FORMAT-concern-ledger.txt' "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: the round-number file name stays on the loop FORMAT" \
    "1" "$(grep -c 'SID-\$FORMAT-round-number.txt' "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: the last-round file name stays on the loop FORMAT" \
    "1" "$(grep -c 'SID-\$FORMAT-last-round.txt' "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: ledger_cli addresses the CLI with LEDGER_FORMAT" \
    "1" "$(grep -c -- '--format "\$LEDGER_FORMAT"' "$LEDGER_VERDICT" 2>/dev/null || true)"
assert_eq "S: ledger_cli no longer passes the loop FORMAT to the CLI" \
    "0" "$(grep -c -- '--format "\$FORMAT"' "$LEDGER_VERDICT" 2>/dev/null || true)"

# --- ref-kind-input.sh's three entry points ---------------------------------
RK_FUNCS="$( ( set +u; . "$REF_KIND" >/dev/null 2>&1 || exit 0
    for f in rk_build_args rk_stage_anchored rk_load_prestaged; do
        declare -f "$f" >/dev/null 2>&1 && printf '%s ' "$f"
    done ) )"
for _f in rk_build_args rk_stage_anchored rk_load_prestaged; do
    assert_contains "S: ref-kind-input.sh provides $_f()" "$_f" "$RK_FUNCS"
done
assert_contains "S: rk_build_args derives the base from the merge-base resolver" \
    "resolve-merge-base.sh" "$(cat "$REF_KIND" 2>/dev/null || true)"

# --- status-header acquisition (S8-b item 6) --------------------------------
assert_eq "S: the header is taken by prefix grep, not by first non-blank line" \
    "1" "$(grep -c "grep -m1 '\^## Codex Review: '" "$LOOP_BIN" 2>/dev/null || true)"
assert_eq "S: the awk first-line acquisition is gone" \
    "0" "$(grep -c "awk 'NF{print; exit}'" "$LOOP_BIN" 2>/dev/null || true)"

# --- the closed producer set (round-2 C3) -----------------------------------
ALLOWED="$(cl cl_allowed_producers review-security-shared 2>/dev/null | grep -v '^$' | LC_ALL=C sort | paste -sd ',' - || true)"
assert_eq "S: cl_allowed_producers is exactly codex + scanner for the shared format" \
    "review-code-codex,security-scanner" "$ALLOWED"
DECLARED="$(cl cl_declared_producers review-security-shared 2>/dev/null | grep -v '^$' | paste -sd ',' - || true)"
assert_eq "S: cl_declared_producers is empty for the shared format (either one suffices)" \
    "" "$DECLARED"
OTHER_ALLOWED="$(cl cl_allowed_producers detail-plan 2>/dev/null | grep -v '^$' | paste -sd ',' - || true)"
assert_eq "S: a format with no closed set keeps the lexical-only check" "" "$OTHER_ALLOWED"

assert_eq "S: the completeness predicate is a single shared function" \
    "1" "$(grep -c 'cl_round_complete_for()' "$AGENTS_ROOT/bin/lib/concern-ledger/core.sh" 2>/dev/null || true)"
assert_match "S: reduce.sh judges completeness through the shared function" \
    'cl_round_complete_for' "$(cat "$AGENTS_ROOT/bin/lib/concern-ledger/reduce.sh" 2>/dev/null || true)"
assert_match "S: check-staged judges completeness through the same function" \
    'cl_round_complete_for' "$(cat "$CL_CLI" 2>/dev/null || true)"

# --- what the migration removes ---------------------------------------------
for _gone in "bin/review-code-ledger" \
             "skills/review-code-security/scripts/open-concern-round.sh" \
             "skills/review-code-security/scripts/close-concern-round.sh"; do
    assert_eq "S: $_gone is deleted" "missing" "$(file_state "$AGENTS_ROOT/$_gone")"
done

# The migration removed bin/review-code-ledger; the production tree (bin, hooks,
# skills, docs) must carry no surviving reference to it. Test files legitimately
# still name the retired command — they assert its removal and exercise the
# reducer's slot-key handling — so the cleanliness contract is scoped to
# production code, not to tests (which would also self-match this very grep).
RCL_REFS="$(grep -rl 'review-code-ledger' "$AGENTS_ROOT/bin" "$AGENTS_ROOT/hooks" \
    "$AGENTS_ROOT/skills" "$AGENTS_ROOT/docs" 2>/dev/null \
    | sed "s|^$AGENTS_ROOT/||" | LC_ALL=C sort | paste -sd ',' - || true)"
assert_eq "S: no production code still references the retired review-code-ledger" \
    "" "$RCL_REFS"

SIDDOC="$AGENTS_ROOT/docs/architecture/claude-code/session-id-resolution.md"
assert_contains "S: the session-id doc names the new chain as the rc-table reader" \
    "run-codex-review-loop" "$(cat "$SIDDOC" 2>/dev/null || true)"

QGATES="$AGENTS_ROOT/skills/review-code-security/scripts/run-quality-gates.sh"
if [ -f "$QGATES" ]; then
    QG_TEXT="$(cat "$QGATES" 2>/dev/null || true)"
    assert_not_contains "S: run-quality-gates.sh no longer runs a codex gate" \
        "review-code-ledger" "$QG_TEXT"
    assert_not_contains "S: run-quality-gates.sh does not call the codex reviewer directly" \
        "review-code-codex" "$QG_TEXT"
else
    fail "S: skills/review-code-security/scripts/run-quality-gates.sh is missing"
fi

# --- the new wrapper (S8-e) -------------------------------------------------
RCS_WRAP="$AGENTS_ROOT/skills/review-code-security/scripts/run-codex-review-loop.sh"
if [ -f "$RCS_WRAP" ]; then
    W_TEXT="$(cat "$RCS_WRAP" 2>/dev/null || true)"
    assert_contains "S: the wrapper selects the security-code format" "--format security-code" "$W_TEXT"
    assert_contains "S: the wrapper resolves the accepted-tradeoffs file" \
        "resolve-accepted-tradeoffs-file" "$W_TEXT"
    assert_contains "S: the wrapper passes the resolved tradeoffs file through" \
        "--accepted-tradeoffs" "$W_TEXT"
    assert_contains "S: the wrapper forwards extra flags such as --prestaged-report" '"$@"' "$W_TEXT"
    assert_not_contains "S: the wrapper passes no --draft-file for a ref-kind format" \
        "--draft-file" "$W_TEXT"
else
    fail "S: skills/review-code-security/scripts/run-codex-review-loop.sh is missing"
fi
