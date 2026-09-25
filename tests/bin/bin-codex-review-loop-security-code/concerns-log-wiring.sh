# tests/bin-codex-review-loop-security-code/concerns-log-wiring.sh
# Tests: skills/review-code-security/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: CTX_CONCERNS_LOG, render-concerns-log, concerns-log, wiring, TL2, scope:issue-specific
# Sourced by tests/bin-codex-review-loop-security-code.sh.
# TL3 gap: real loop/codex/concern-ledger not exercised; skill wrappers driven with
# stubs via AGENTS_CONFIG_DIR. Mitigation: full-chain-integration.sh + manual runs.

echo ""
echo "--- E: skill wrapper concerns-log wiring (change 6) ---"

_EW_DETAIL_WRAPPER="$AGENTS_ROOT/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
_EW_SEC_WRAPPER="$WRAPPER"
# The three remaining MUST wrappers (CPR-ORTH: symmetric treatment of the class).
_EW_OUTLINE_WRAPPER="$AGENTS_ROOT/skills/make-outline-plan/scripts/run-codex-review-loop.sh"
_EW_PLANSEC_WRAPPER="$AGENTS_ROOT/skills/review-plan-security/scripts/run-codex-review-loop.sh"
_EW_TESTS_WRAPPER="$AGENTS_ROOT/skills/review-tests/scripts/run-codex-review-loop.sh"
_EW_SEQ=0

for _ewf in "$_EW_DETAIL_WRAPPER" "$_EW_SEC_WRAPPER" \
            "$_EW_OUTLINE_WRAPPER" "$_EW_PLANSEC_WRAPPER" "$_EW_TESTS_WRAPPER"; do
    if [ ! -f "$_ewf" ]; then
        fail "E: implementation missing: ${_ewf#"$AGENTS_ROOT/"} (E cases fail for this reason)"
    fi
done

# _ew_setup <render-exit> <carrier-path-or-empty> — initialises per-case stub dirs.
# render-exit: 0 carrier, 3 no-ledger, 5 write-error.
# Outputs: EW_SDIR EW_PLANS EW_SID EW_CAP EW_CL_LOG EW_ERR
_ew_setup() {
    _EW_SEQ=$((_EW_SEQ + 1))
    local re="$1" carrier="${2:-}"
    EW_SDIR="$TMPDIR_BASE/ew-stub-$_EW_SEQ"
    EW_PLANS="$TMPDIR_BASE/ew-plans-$_EW_SEQ"
    EW_SID="ews$_EW_SEQ"
    EW_CAP="$TMPDIR_BASE/ew-cap-$_EW_SEQ.txt"
    EW_CL_LOG="$TMPDIR_BASE/ew-cl-$_EW_SEQ.txt"
    EW_ERR="$TMPDIR_BASE/ew-err-$_EW_SEQ.txt"
    mkdir -p "$EW_SDIR/bin" "$EW_PLANS"
    printf 'none\n' > "$EW_PLANS/tradeoffs.md"

    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit 0\n' \
        "$EW_PLANS/tradeoffs.md" > "$EW_SDIR/bin/resolve-accepted-tradeoffs-file"
    chmod +x "$EW_SDIR/bin/resolve-accepted-tradeoffs-file"

    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\nexit 0\n' \
        "$EW_CAP" > "$EW_SDIR/bin/run-codex-review-loop"
    chmod +x "$EW_SDIR/bin/run-codex-review-loop"

    # review-tests wrapper needs a resolvable commit target before it reaches the
    # wiring point; stub the two resolvers so it does not bail out at exit 3.
    # resolve-session-id: exit 2 = "no session" (legit → CC_SID empty).
    printf '#!/usr/bin/env bash\nexit 2\n' > "$EW_SDIR/bin/resolve-session-id"
    chmod +x "$EW_SDIR/bin/resolve-session-id"
    # resolve-worktree-path: echo the plans dir so COMMIT_TARGET is a real dir.
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit 0\n' \
        "$EW_PLANS" > "$EW_SDIR/bin/resolve-worktree-path"
    chmod +x "$EW_SDIR/bin/resolve-worktree-path"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "${1:-}" = "render-concerns-log" ]; then\n'
        printf '  printf "%%s\\n" "$*" >> "%s"\n' "$EW_CL_LOG"
        if [ "$re" = "0" ]; then
            printf '  printf "%%s\\n" "%s"\n' "$carrier"
            printf '  exit 0\n'
        elif [ "$re" = "3" ]; then
            printf '  exit 3\n'
        elif [ "$re" = "5" ]; then
            printf '  printf "concern-ledger: render-concerns-log: write failure\\n" >&2\n'
            printf '  exit 5\n'
        fi
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$EW_SDIR/bin/concern-ledger"
    chmod +x "$EW_SDIR/bin/concern-ledger"
}

# _ew_run <wrapper-path> [<stale-ctx-path>] — runs wrapper in isolated subshell.
# Outputs: EW_RC EW_STDERR EW_ARGS EW_CL_ARGS
_ew_run() {
    local wrap="$1" stale="${2:-}"
    : > "$EW_CAP"; : > "$EW_CL_LOG"; : > "$EW_ERR"
    EW_RC=0
    (
        export AGENTS_CONFIG_DIR="$EW_SDIR"
        export SESSION_ID="$EW_SID"
        export PLANS_DIR="$EW_PLANS"
        export EXTENSIONS_USED="0"
        # Keep the review-tests wrapper out of its git merge-base scope block.
        export REVIEW_TESTS_FULL_SCAN="1"
        unset CTX_SURVEY_CODE CTX_SURVEY_HISTORY CTX_CONCERNS_LOG 2>/dev/null || true
        if [ -n "$stale" ]; then export CTX_CONCERNS_LOG="$stale"; fi
        cd "$TMPDIR_BASE"
        bash "$wrap"
    ) 2>"$EW_ERR" || EW_RC=$?
    EW_STDERR="$(cat "$EW_ERR" 2>/dev/null || true)"
    EW_ARGS="$(cat "$EW_CAP" 2>/dev/null || true)"
    EW_CL_ARGS="$(cat "$EW_CL_LOG" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# E1: detail-plan: render exit 0 → carrier path forwarded as --context
# ---------------------------------------------------------------------------
echo "E1: detail-plan wrapper: render exit 0 → carrier in --context"
{
    EW_CARRIER_E1="$TMPDIR_BASE/ew-carrier-e1.txt"
    printf 'carrier-content-e1\n' > "$EW_CARRIER_E1"
    _ew_setup 0 "$EW_CARRIER_E1"
    _ew_run "$_EW_DETAIL_WRAPPER"

    assert_contains "E1: run-codex-review-loop captured args (anti-false-positive)" \
        "--format detail-plan" "$EW_ARGS"
    assert_contains "E1: render-concerns-log was called" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "E1: carrier path forwarded as --context" \
        "--context $EW_CARRIER_E1" "$EW_ARGS"
}

# ---------------------------------------------------------------------------
# E1b: detail-plan: render exit 3 (benign, no ledger) → no warning, no --context
# E1c: detail-plan: render exit 5 → stderr warning, loop continues, wrapper exit 0
# (CPR-ORTH: symmetric coverage with review-code-security below)
# ---------------------------------------------------------------------------
echo "E1b: detail-plan wrapper: render exit 3 (benign) → no --context"
{
    _ew_setup 3 ""
    _ew_run "$_EW_DETAIL_WRAPPER"
    assert_contains "E1b: loop called (anti-false-positive)" "--format detail-plan" "$EW_ARGS"
    assert_contains "E1b: render-concerns-log was called (RED until change 6)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_not_contains "E1b: no stderr warning on benign absent ledger" \
        "concern-ledger:" "$EW_STDERR"
    assert_not_contains "E1b: no --context when ledger absent" "--context" "$EW_ARGS"
}

echo "E1c: detail-plan wrapper: render exit 5 → stderr warning + loop continues"
{
    _ew_setup 5 ""
    _ew_run "$_EW_DETAIL_WRAPPER"
    assert_contains "E1c: render-concerns-log was called (RED until change 6)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "E1c: stderr carries concern-ledger warning (RED until change 6)" \
        "render-concerns-log" "$EW_STDERR"
    assert_contains "E1c: loop continues — run-codex-review-loop still invoked" \
        "--format detail-plan" "$EW_ARGS"
    assert_eq "E1c: wrapper exit 0 (set -e not tripped on exit 5)" "0" "$EW_RC"
}

# ---------------------------------------------------------------------------
# E2: review-code-security: concern-ledger invoked with format review-security-shared
# ---------------------------------------------------------------------------
echo "E2: review-code-security: LFMT = review-security-shared"
{
    EW_CARRIER_E2="$TMPDIR_BASE/ew-carrier-e2.txt"
    printf 'carrier-content-e2\n' > "$EW_CARRIER_E2"
    _ew_setup 0 "$EW_CARRIER_E2"
    _ew_run "$_EW_SEC_WRAPPER"

    assert_contains "E2: render-concerns-log was called (anti-false-positive)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "E2: format arg is review-security-shared" \
        "--format review-security-shared" "$EW_CL_ARGS"
    assert_not_contains "E2: format is not review-code-security" \
        "--format review-code-security" "$EW_CL_ARGS"
}

# ---------------------------------------------------------------------------
# E3: stale CTX_CONCERNS_LOG is cleared when ledger absent (render exit 3)
# ---------------------------------------------------------------------------
echo "E3: stale CTX_CONCERNS_LOG absent from --context when ledger absent"
{
    EW_STALE_E3="$TMPDIR_BASE/ew-stale-e3.txt"
    printf 'stale-carrier-content\n' > "$EW_STALE_E3"
    _ew_setup 3 ""
    _ew_run "$_EW_SEC_WRAPPER" "$EW_STALE_E3"

    assert_contains "E3: run-codex-review-loop captured args (anti-false-positive)" \
        "--format security-code" "$EW_ARGS"
    assert_contains "E3: render-concerns-log was called" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_not_contains "E3: stale CTX_CONCERNS_LOG absent from --context" \
        "$EW_STALE_E3" "$EW_ARGS"
}

# ---------------------------------------------------------------------------
# E4: render exit 5 → stderr warning, loop continues, CTX unset
# ---------------------------------------------------------------------------
echo "E4: render exit 5 → stderr warning + loop continues + no carrier"
{
    _ew_setup 5 ""
    _ew_run "$_EW_SEC_WRAPPER"

    assert_contains "E4: render-concerns-log was called" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "E4: stderr carries concern-ledger warning" \
        "render-concerns-log" "$EW_STDERR"
    assert_contains "E4: loop continues — run-codex-review-loop still invoked" \
        "--format security-code" "$EW_ARGS"
    assert_eq "E4: wrapper exit 0 (set -e not tripped on exit 5)" "0" "$EW_RC"
}

# ---------------------------------------------------------------------------
# E5: render exit 3 (no ledger, benign) → no warning, no --context
# ---------------------------------------------------------------------------
echo "E5: render exit 3 (benign) → no stderr warning, no --context"
{
    _ew_setup 3 ""
    _ew_run "$_EW_SEC_WRAPPER"

    assert_contains "E5: render-concerns-log was called" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_not_contains "E5: no stderr warning on benign absent ledger" \
        "concern-ledger:" "$EW_STDERR"
    assert_contains "E5: run-codex-review-loop was called (anti-false-positive)" \
        "--format security-code" "$EW_ARGS"
    assert_not_contains "E5: no --context from concerns log when ledger absent" \
        "--context" "$EW_ARGS"
}

# E6-E14: the three remaining MUST wrappers (make-outline-plan,
# review-plan-security, review-tests), each across render exit 0/3/5 (CPR-ORTH:
# same class treatment as make-detail-plan / review-code-security above).
# Change 6 wiring is absent in these three, so "render-concerns-log was called"
# is RED by design until /write-code; stubs let each wrapper run to completion
# so the RED is an assertion failure, not a harness crash. Plan formats use a
# ledger format equal to the loop --format (review-code-security differs).

# _ew_suite <label> <wrapper> <ledger-fmt> <loop-fmt>
_ew_suite() {
    local label="$1" wrap="$2" lfmt="$3" loopfmt="$4"

    echo "$label (exit 0): render → carrier forwarded as --context, ledger fmt $lfmt"
    local carrier="$TMPDIR_BASE/ew-carrier-$label.txt"
    printf 'carrier-content-%s\n' "$label" > "$carrier"
    _ew_setup 0 "$carrier"
    _ew_run "$wrap"
    assert_contains "$label/0: run-codex-review-loop captured args (anti-false-positive)" \
        "--format $loopfmt" "$EW_ARGS"
    assert_contains "$label/0: render-concerns-log was called (RED until change 6)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "$label/0: render-concerns-log used ledger format $lfmt" \
        "--format $lfmt" "$EW_CL_ARGS"
    assert_contains "$label/0: carrier path forwarded as --context" \
        "--context $carrier" "$EW_ARGS"

    echo "$label (exit 3): benign no-ledger → no warning, no --context"
    _ew_setup 3 ""
    _ew_run "$wrap"
    assert_contains "$label/3: run-codex-review-loop was called (anti-false-positive)" \
        "--format $loopfmt" "$EW_ARGS"
    assert_contains "$label/3: render-concerns-log was called (RED until change 6)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_not_contains "$label/3: no stderr warning on benign absent ledger" \
        "concern-ledger:" "$EW_STDERR"
    assert_not_contains "$label/3: no --context from concerns log when ledger absent" \
        "--context" "$EW_ARGS"

    echo "$label (exit 5): render failure → stderr warning, loop continues, wrapper exit 0"
    _ew_setup 5 ""
    _ew_run "$wrap"
    assert_contains "$label/5: render-concerns-log was called (RED until change 6)" \
        "render-concerns-log" "$EW_CL_ARGS"
    assert_contains "$label/5: stderr carries concern-ledger warning (RED until change 6)" \
        "render-concerns-log" "$EW_STDERR"
    assert_contains "$label/5: loop continues — run-codex-review-loop still invoked" \
        "--format $loopfmt" "$EW_ARGS"
    assert_eq "$label/5: wrapper exit 0 (set -e not tripped on exit 5)" "0" "$EW_RC"
}

_ew_suite "outline"  "$_EW_OUTLINE_WRAPPER" "outline-plan"  "outline-plan"
_ew_suite "plansec"  "$_EW_PLANSEC_WRAPPER" "security-plan" "security-plan"
_ew_suite "revtests" "$_EW_TESTS_WRAPPER"   "test-review"   "test-review"
