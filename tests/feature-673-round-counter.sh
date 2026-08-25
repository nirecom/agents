#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: round-counter, review-loop, planning, plans, scope:issue-specific, TL2
# The round number used to be minted by each stage wrapper and consumed by the
# shared loop, so the two could disagree — a round the ledger never recorded was
# reported as approved (#2068). One owner now: bin/run-codex-review-loop.
# Counter file: <PLANS_DIR>/<session-id>-<format>-round-number.txt (#866).
set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
DETAIL_WRAPPER="$AGENTS_WORKTREE/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
OUTLINE_WRAPPER="$AGENTS_WORKTREE/skills/make-outline-plan/scripts/run-codex-review-loop.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [[ ! -f "$DETAIL_WRAPPER" ]]; then
    echo "SKIP: $DETAIL_WRAPPER does not exist"
    exit 0
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# A. No stage wrapper mints or passes a round number any more. All four are
#    checked together: a counter left in one of them is the same dual-management
#    bug as leaving it in all four (CPR-ORTH).
# ---------------------------------------------------------------------------
while IFS='|' read -r SKILL_NAME; do
    SKILL_NAME="${SKILL_NAME// /}"
    [[ -z "$SKILL_NAME" ]] && continue
    case "$SKILL_NAME" in \#*) continue ;; esac
    W="$AGENTS_WORKTREE/skills/$SKILL_NAME/scripts/run-codex-review-loop.sh"
    if [[ ! -f "$W" ]]; then
        fail "A: $SKILL_NAME wrapper missing at $W"
        continue
    fi
    if grep -q -- "round-number" "$W"; then
        fail "A: $SKILL_NAME still owns a round-number file — two writers again"
    else
        pass "A: $SKILL_NAME keeps no round-number file of its own"
    fi
    if grep -qE -- '--round[ =]' "$W"; then
        fail "A: $SKILL_NAME still dictates --round to the loop that numbers rounds"
    else
        pass "A: $SKILL_NAME does not dictate --round"
    fi
done <<'WRAPPERS'
make-detail-plan
make-outline-plan
review-plan-security
review-tests
WRAPPERS

if grep -q -- "round-number" "$AGENTS_WORKTREE/bin/run-codex-review-loop"; then
    pass "A: the shared loop is where the counter now lives"
else
    fail "A: nobody owns the round counter — the shared loop does not name round-number"
fi

# ---------------------------------------------------------------------------
# Fixture: a mock AGENTS_CONFIG_DIR holding the REAL shared loop and its libs,
# with only the codex-facing reviewer stubbed. The stub records the argv it was
# handed, which is how the round the loop minted becomes observable.
# ---------------------------------------------------------------------------
ENV_SEQ=0
mk_env() {
    ENV_SEQ=$((ENV_SEQ + 1))
    MOCK="$TMPDIR_BASE/env$ENV_SEQ/agents"
    PLANS="$TMPDIR_BASE/env$ENV_SEQ/plans"
    ARGV_FILE="$TMPDIR_BASE/env$ENV_SEQ/run-loop-argv.txt"
    BODY_FILE="$TMPDIR_BASE/env$ENV_SEQ/reviewer-body.txt"
    RV_FILE="$TMPDIR_BASE/env$ENV_SEQ/reviewer-rc.txt"
    mkdir -p "$MOCK/bin/lib" "$MOCK/rules" "$PLANS"
    printf '# core principles stub\n' > "$MOCK/rules/core-principles.md"
    printf '0\n' > "$RV_FILE"

    cat > "$MOCK/bin/build-codex-context" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) : > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB
    chmod +x "$MOCK/bin/build-codex-context"

    cat > "$MOCK/bin/review-plan-codex" <<STUB
#!/usr/bin/env bash
echo "ARGS: \$*" > "$ARGV_FILE"
RC=\$(cat "$RV_FILE")
[[ "\$RC" != "0" ]] && exit "\$RC"
cat "$BODY_FILE"
exit 0
STUB
    chmod +x "$MOCK/bin/review-plan-codex"

    local f
    for f in run-codex-review-loop review-loop-verdict concern-ledger; do
        [[ -f "$AGENTS_WORKTREE/bin/$f" ]] || continue
        cp "$AGENTS_WORKTREE/bin/$f" "$MOCK/bin/$f"
        chmod +x "$MOCK/bin/$f"
    done
    for f in codex-core.sh codex-timeout.sh concern-ledger.sh safe-plans-path.sh; do
        [[ -f "$AGENTS_WORKTREE/bin/lib/$f" ]] && cp "$AGENTS_WORKTREE/bin/lib/$f" "$MOCK/bin/lib/$f"
    done
    [[ -d "$AGENTS_WORKTREE/bin/lib/concern-ledger" ]] && cp -r "$AGENTS_WORKTREE/bin/lib/concern-ledger" "$MOCK/bin/lib/"
    [[ -d "$AGENTS_WORKTREE/bin/lib/codex-review-loop" ]] && cp -r "$AGENTS_WORKTREE/bin/lib/codex-review-loop" "$MOCK/bin/lib/"
    return 0
}

# set_body <sid> <verdict-line> [concern-line] — what the stubbed reviewer says.
set_body() {
    {
        printf '## Codex Plan Review: PERFORMED\n\n'
        printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
        printf '%s\n' "$2"
        [[ -n "${3:-}" ]] && printf '%s\n' "$3"
        printf '<!-- end-codex-output -->\n'
    } > "$BODY_FILE"
}

CONCERN="the round the ledger never saw must not be reported as approved"

# seed_drafts <sid> — the input files the detail stage wrapper points at.
seed_drafts() {
    printf '# Draft\n' > "$PLANS/$1-detail.md"
    printf '# Outline\n' > "$PLANS/$1-outline.md"
}

# invoke_detail <sid> <extensions-used> → prints the wrapper's exit code
invoke_detail() {
    local rc=0
    AGENTS_CONFIG_DIR="$MOCK" SESSION_ID="$1" PLANS_DIR="$PLANS" \
        EXTENSIONS_USED="$2" \
        run_with_timeout bash "$DETAIL_WRAPPER" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

counter_file() { echo "$PLANS/$1-$2-round-number.txt"; }
argv_has_round() { grep -q -- "--round $1" "$ARGV_FILE" 2>/dev/null; }
counter_value() { tr -d '[:space:]' < "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1-3. The loop numbers each round from the counter it owns: absent means 1,
#      each continuing round one higher. Round 2 onward re-raises the same
#      concern by round 1's ID, since a fresh number would never converge.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid1
    set_body sid1 "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    invoke_detail sid1 0 >/dev/null
    if argv_has_round 1; then
        pass "1: with no counter on disk the loop opens at round 1"
    else
        fail "1: expected --round 1. Got: $(cat "$ARGV_FILE" 2>/dev/null)"
    fi

    set_body sid1 "NEEDS_REVISION" "C1: $CONCERN"
    invoke_detail sid1 0 >/dev/null
    if argv_has_round 2; then
        pass "2: the next round is numbered from the counter, not from the caller"
    else
        fail "2: expected --round 2. Got: $(cat "$ARGV_FILE" 2>/dev/null)"
    fi

    invoke_detail sid1 1 >/dev/null
    if argv_has_round 3; then
        pass "3: an extension does not renumber the round it extends into"
    else
        fail "3: expected --round 3. Got: $(cat "$ARGV_FILE" 2>/dev/null)"
    fi
}

# ---------------------------------------------------------------------------
# 4. APPROVED ends the loop, so the counter is retired: the next session-format
#    pair must start from 1 again rather than inheriting a stale number.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid4
    set_body sid4 "APPROVED"
    RC=$(invoke_detail sid4 0)
    CFILE=$(counter_file sid4 detail-plan)
    if [[ "$RC" == "0" && ! -f "$CFILE" ]]; then
        pass "4: APPROVED (exit 0) retires the counter"
    else
        fail "4: rc=$RC, counter=$([[ -f "$CFILE" ]] && echo "present($(counter_value "$CFILE"))" || echo absent)"
    fi
}

# ---------------------------------------------------------------------------
# 5. ESCALATE is terminal too. Reached the honest way: round 1 leaves a HIGH
#    open, then the cap round runs with the extension budget spent and a risk
#    signal on file.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid5
    set_body sid5 "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    invoke_detail sid5 0 >/dev/null
    printf 'hook-registration\n' > "$PLANS/sid5-detail-risk-signal.txt"
    set_body sid5 "NEEDS_REVISION" "C1: $CONCERN"
    RC=$(invoke_detail sid5 1)
    CFILE=$(counter_file sid5 detail-plan)
    if [[ "$RC" == "2" && ! -f "$CFILE" ]]; then
        pass "5: ESCALATE (exit 2) retires the counter"
    else
        fail "5: rc=$RC (want 2), counter=$([[ -f "$CFILE" ]] && echo present || echo absent)"
    fi
}

# ---------------------------------------------------------------------------
# 6. CONTINUE is not terminal, so the round it just consumed stays consumed.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid6
    set_body sid6 "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    RC=$(invoke_detail sid6 0)
    CFILE=$(counter_file sid6 detail-plan)
    if [[ "$RC" == "1" && "$(counter_value "$CFILE")" == "1" ]]; then
        pass "6: CONTINUE (exit 1) keeps the counter at the round it consumed"
    else
        fail "6: rc=$RC, counter=$(counter_value "$CFILE" || echo absent) (want 1)"
    fi
}

# ---------------------------------------------------------------------------
# 7. exit 3 means codex never reviewed anything, so no round was spent. The
#    counter rolls back to its pre-call value (#776): a retry re-runs the
#    same number, keeping ledger concern IDs continuous.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid7
    printf '1\n' > "$RV_FILE"
    RC=$(invoke_detail sid7 0)
    CFILE=$(counter_file sid7 detail-plan)
    if [[ "$RC" == "3" && ! -f "$CFILE" ]]; then
        pass "7: exit 3 on the first round leaves no counter behind"
    else
        fail "7: rc=$RC (want 3), counter=$([[ -f "$CFILE" ]] && echo "present($(counter_value "$CFILE"))" || echo absent)"
    fi
}
{
    mk_env; seed_drafts sid7b
    set_body sid7b "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    invoke_detail sid7b 0 >/dev/null
    printf '1\n' > "$RV_FILE"
    RC=$(invoke_detail sid7b 0)
    CFILE=$(counter_file sid7b detail-plan)
    if [[ "$RC" == "3" && "$(counter_value "$CFILE")" == "1" ]]; then
        pass "7b: exit 3 rolls the counter back to its pre-call value, not to zero"
    else
        fail "7b: rc=$RC (want 3), counter=$(counter_value "$CFILE" || echo absent) (want 1)"
    fi
}

# ---------------------------------------------------------------------------
# 8. EXTENSIONS_USED is the caller's budget, not the round number. Raising it
#    must not reset or skip the count.
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts sid8
    set_body sid8 "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    invoke_detail sid8 0 >/dev/null
    set_body sid8 "NEEDS_REVISION" "C1: $CONCERN"
    invoke_detail sid8 1 >/dev/null
    if argv_has_round 2; then
        pass "8: EXTENSIONS_USED=1 does not renumber the round (still 2)"
    else
        fail "8: expected --round 2 with EXTENSIONS_USED=1. Got: $(cat "$ARGV_FILE" 2>/dev/null)"
    fi
}

# ---------------------------------------------------------------------------
# 9. The counter's address is per session and per format, so two formats in one
#    session never share a number (#866: flat under PLANS_DIR).
# ---------------------------------------------------------------------------
{
    mk_env; seed_drafts mysid
    set_body mysid "NEEDS_REVISION" "1. [HIGH] $CONCERN"
    invoke_detail mysid 0 >/dev/null
    EXPECTED="$PLANS/mysid-detail-plan-round-number.txt"
    if [[ -f "$EXPECTED" ]]; then
        pass "9: counter at <plans>/<sid>-detail-plan-round-number.txt"
    else
        fail "9: counter not at $EXPECTED. Listing: $(ls "$PLANS/" 2>/dev/null)"
    fi

    if [[ -f "$OUTLINE_WRAPPER" ]]; then
        set_body mysid "MISSING_ALTERNATIVE: a third approach was never considered" "1. [HIGH] $CONCERN"
        AGENTS_CONFIG_DIR="$MOCK" SESSION_ID="mysid" PLANS_DIR="$PLANS" EXTENSIONS_USED="0" \
            run_with_timeout bash "$OUTLINE_WRAPPER" >/dev/null 2>&1 || true
        OEXPECTED="$PLANS/mysid-outline-plan-round-number.txt"
        DVAL="$(counter_value "$EXPECTED")"
        if [[ -f "$OEXPECTED" || "$DVAL" == "1" ]]; then
            pass "9b: outline-plan counts on its own address, leaving detail-plan's at $DVAL"
        else
            fail "9b: outline round leaked into detail-plan's counter (now $DVAL). Listing: $(ls "$PLANS/" 2>/dev/null)"
        fi
    else
        echo "SKIP-9b: outline wrapper not present"
    fi
}

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
