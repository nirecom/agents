#!/bin/bash
# Tests: skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md, skills/update-docs/SKILL.md, skills/worktree-start/SKILL.md, skills/write-code/SKILL.md, skills/write-tests/SKILL.md, tests/install-path-exposed-commands.sh
# Tags: worktree, start, outline, planning, detail, xfail-ledger, TL2, scope:common
# Static grep-based checks for the confirm-flags feature wiring.

# Verifies that the gated skills reference the helper script, that the matching
# CONFIRM_* flag names exist in .env.example, that the PATH-exposure contract for
# `get-config-var` is still OWNED by a live check in
# tests/install-path-exposed-commands.sh, and that legacy chat-emit / summary lines
# have been removed while load-bearing instructions are preserved.

# Section 9 no longer greps the two installer scripts for the literal string
# `get-config-var`. Neither installer names any individual command any more: both
# loop over the shared list install/path-exposed-commands.txt, so the literal check
# went permanently red without anything being broken (#1967). What section 9 checks
# now is that the delegate which owns that fact is still alive.

# KNOWN RED LEDGER. Some checks below are known to fail and are NOT repaired by this
# file's PR. They are enumerated in EXPECTED_FAILURES and reported as XFAIL, which
# does not colour the exit code. Anything else exits 1: a new FAIL, an XPASS (a
# ledger entry that started passing, so the ledger must be pruned), or a
# STALE-LEDGER entry (an id no check site reports any more). `grep EXPECTED_FAILURES`
# is the single entry point.

# TL3 gap (what this test does NOT catch):
# - Whether `get-config-var` actually RESOLVES on PATH in a real session: every check
#   here greps SKILL.md TEXT, and the shim is written by installers that never run.
# - Whether a skill that greps green really gates at run time -- a bare-name call that
#   exits 127 is swallowed by the surrounding `|| true`, invisible to a static check.
# - Whether section 9's delegate, tests/install-path-exposed-commands.sh, actually
#   PASSES: it costs 348-460 s and is only grepped from here, never executed.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh categories: installer (PATH exposure) and
# skill-orchestration (the SKILL.md gates themselves).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
XFAIL=0
UNEXPECTED=0
OBSERVED_IDS=""

# ---------------------------------------------------------------------------
# EXPECTED_FAILURES -- the known-RED ledger (tracked in #2054)
# ---------------------------------------------------------------------------
# One stable check id per line; everything after `#` on a line is commentary.
# Two classes, kept apart on purpose (CPR-SC): (a) SKILL.md files that moved to a
# different wrapper, leaving a literal-string check pointing at nothing, and
# (b) outline SKILL.md preserved-wording pins whose wording changed.
EXPECTED_FAILURES='
C2-make-outline-plan                            # (a) literal `get-config-var --is-off` moved behind a wrapper -- tracked in #2054
C2-write-tests                                  # (a) same -- tracked in #2054
C2-worktree-start                               # (a) same -- tracked in #2054
C2-write-code                                   # (a) same -- tracked in #2054
C2-update-docs                                  # (a) same -- tracked in #2054
C5-outline-preserve-mark-step-detail-complete   # (b) outline SKILL.md preserved-wording pin went stale -- tracked in #2054
C5-outline-preserve-askuserquestion-on-mode     # (b) same -- tracked in #2054
'

ledger_ids() {
    printf '%s\n' "$EXPECTED_FAILURES" \
        | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$'
}
in_ledger() { ledger_ids | grep -qx -- "$1"; }

# A duplicated ledger id is silent damage: `in_ledger` still answers yes, but the
# ledger no longer says how many known failures there are, and the STALE-LEDGER
# sweep below would report the same key twice. Abort on the spot instead.
# (Deliberately NOT validated here: the `tracked in #NNNN` commentary itself --
# the ledger keys on the ids, and a tracking number going stale is paperwork
# drift, not a test signal.)
assert_ledger_unique() {
    local dups
    dups="$(ledger_ids | sort | uniq -d | tr '\n' ' ')"
    if [ -n "${dups// /}" ]; then
        echo "HARNESS ERROR: duplicate id(s) in EXPECTED_FAILURES: ${dups% }" >&2
        exit 2
    fi
}
assert_ledger_unique

# An id typo or an argument slipped by one would otherwise land silently in the
# message text and quietly detach a check from the ledger. Abort instead.
assert_id() {
    case "${1:-}" in
        '' | *[!A-Za-z0-9-]*)
            echo "HARNESS ERROR: invalid check id '${1:-}' (expected ^[A-Za-z0-9-]+\$)" >&2
            exit 2
            ;;
    esac
}

record_observed() { OBSERVED_IDS="$OBSERVED_IDS$1
"; }

fail() { # <id> <msg>
    assert_id "$1"
    record_observed "$1"
    if in_ledger "$1"; then
        echo "XFAIL: [$1] $2"
        XFAIL=$((XFAIL + 1))
    else
        echo "FAIL: [$1] $2"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
}

pass() { # <id> <msg>
    assert_id "$1"
    record_observed "$1"
    if in_ledger "$1"; then
        echo "XPASS: [$1] this known-RED entry now passes; remove it from EXPECTED_FAILURES"
        UNEXPECTED=$((UNEXPECTED + 1))
    else
        echo "PASS: [$1] $2"
        PASSED=$((PASSED + 1))
    fi
}

# grep wrapper that returns 0/1 (no -q so we can suppress output uniformly)
has() {
    # has <pattern> <file>
    grep -E -- "$1" "$2" >/dev/null 2>&1
}
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}
count_fixed() {
    # count_fixed <fixed-string> <file>
    grep -F -c -- "$1" "$2" 2>/dev/null || echo 0
}

OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"
WORKTREE_SKILL="$REPO_ROOT/skills/worktree-start/SKILL.md"
TESTS_SKILL="$REPO_ROOT/skills/write-tests/SKILL.md"
WRITE_CODE_SKILL="$REPO_ROOT/skills/write-code/SKILL.md"
UPDATE_DOCS_SKILL="$REPO_ROOT/skills/update-docs/SKILL.md"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
# OWNER_TEST_OVERRIDE is a test seam, never set in a normal run: it lets
# tests/fix-1967-c9-delegation-mutation.sh point section 9 at a MUTATED temp copy of
# the owner test and prove that C9-a..C9-d actually go red when the delegate is
# deleted, unhooked from the run list, renamed away from `get-config-var`, or
# hollowed out. The C9 predicates stay defined here and only here (CPR-SSOT); the
# mutation harness re-runs this same file rather than transcribing them.
OWNER_TEST="${OWNER_TEST_OVERRIDE:-$REPO_ROOT/tests/install-path-exposed-commands.sh}"

require_file() { # <id> <path>
    if [ ! -f "$2" ]; then
        fail "$1" "missing required file: $2"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 1. Each SKILL.md references its matching CONFIRM_* flag
# ---------------------------------------------------------------------------
# Ids carry `-` where the flag carries `_`: the id charset is ^[A-Za-z0-9-]+$ so a
# ledger key can never be confused with the message text next to it.
echo "=== SKILL.md flag references ==="
declare -a SKILL_FLAG_PAIRS=(
    "$OUTLINE_SKILL|CONFIRM_OUTLINE"
    "$DETAIL_SKILL|CONFIRM_DETAIL"
    "$TESTS_SKILL|CONFIRM_TESTS"
    "$WORKTREE_SKILL|CONFIRM_WORKTREE"
    "$WRITE_CODE_SKILL|CONFIRM_CODE"
    "$UPDATE_DOCS_SKILL|CONFIRM_DOCS"
)
for pair in "${SKILL_FLAG_PAIRS[@]}"; do
    file="${pair%%|*}"
    flag="${pair##*|}"
    id="C1-$(printf '%s' "$flag" | tr '_' '-')"
    if require_file "REQFILE-$(basename "$(dirname "$file")")" "$file"; then
        if has_fixed "$flag" "$file"; then
            pass "$id" "$flag referenced in $(basename "$(dirname "$file")")/SKILL.md"
        else
            fail "$id" "$flag missing from $file"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 2. Each gated SKILL.md invokes `get-config-var --is-off`
# ---------------------------------------------------------------------------
echo "=== SKILL.md invokes get-config-var --is-off ==="
for f in "$OUTLINE_SKILL" "$TESTS_SKILL" "$WORKTREE_SKILL" "$WRITE_CODE_SKILL" "$UPDATE_DOCS_SKILL"; do
    slug="$(basename "$(dirname "$f")")"
    if require_file "REQFILE-$slug" "$f"; then
        if has_fixed "get-config-var --is-off" "$f"; then
            pass "C2-$slug" "get-config-var --is-off present in $slug/SKILL.md"
        else
            fail "C2-$slug" "get-config-var --is-off missing from $f"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 3. make-outline-plan / make-detail-plan: required new content
# ---------------------------------------------------------------------------
# `id|needle` pairs rather than a bare needle list: the id must survive editing,
# reordering, or extending the needles, which an array-index-derived id would not.
echo "=== make-outline-plan: required content ==="
if require_file "REQFILE-make-outline-plan" "$OUTLINE_SKILL"; then
    for entry in "C3-outline-round-n-approved|Round N: APPROVED" "C3-outline-debug-log|outline-debug.log"; do
        id="${entry%%|*}"
        needle="${entry#*|}"
        if has_fixed "$needle" "$OUTLINE_SKILL"; then
            pass "$id" "outline SKILL.md contains '$needle'"
        else
            fail "$id" "outline SKILL.md missing '$needle'"
        fi
    done
fi

echo "=== make-detail-plan: required content ==="
if require_file "REQFILE-make-detail-plan" "$DETAIL_SKILL"; then
    for entry in "C3-detail-round-n-approved|Round N: APPROVED" "C3-detail-debug-log|detail-debug.log"; do
        id="${entry%%|*}"
        needle="${entry#*|}"
        if has_fixed "$needle" "$DETAIL_SKILL"; then
            pass "$id" "detail SKILL.md contains '$needle'"
        else
            fail "$id" "detail SKILL.md missing '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 4. Removed legacy content
# ---------------------------------------------------------------------------
echo "=== Removed legacy lines ==="
for f in "$OUTLINE_SKILL" "$DETAIL_SKILL"; do
    name="$(basename "$(dirname "$f")")"
    if require_file "REQFILE-$name" "$f"; then
        n=$(grep -F -c -- "summarizes each discussion round" "$f" 2>/dev/null | head -1)
        # Defensive: ensure n is numeric
        case "$n" in ''|*[!0-9]*) n=0;; esac
        if [ "$n" = "0" ]; then
            pass "C4-$name-summarizes" "'summarizes each discussion round' removed from $name/SKILL.md"
        else
            fail "C4-$name-summarizes" "'summarizes each discussion round' still present ($n hits) in $name/SKILL.md"
        fi
        # The legacy chat-emit was a markdown blockquote ending with "falling back
        # to Claude reviewer for this round." — that suffix is the unambiguous marker.
        needle="falling back to Claude reviewer for this round"
        if has_fixed "$needle" "$f"; then
            fail "C4-$name-chat-emit" "legacy chat-emit '$needle' still present in $name/SKILL.md"
        else
            pass "C4-$name-chat-emit" "legacy chat-emit '$needle' removed from $name/SKILL.md"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 5. Preserved instructions (outline)
# ---------------------------------------------------------------------------
echo "=== make-outline-plan: preserved instructions ==="
if require_file "REQFILE-make-outline-plan" "$OUTLINE_SKILL"; then
    for entry in \
        "C5-outline-preserve-planner-reviewer-no-details|outline-planner and outline-reviewer never see implementation details" \
        "C5-outline-preserve-mark-step-detail-complete|\`WORKFLOW_MARK_STEP_detail_complete\` is NOT emitted here" \
        "C5-outline-preserve-askuserquestion-on-mode|One \`AskUserQuestion\` + one sentinel dialog per run in ON mode"
    do
        id="${entry%%|*}"
        needle="${entry#*|}"
        if has_fixed "$needle" "$OUTLINE_SKILL"; then
            pass "$id" "outline SKILL.md preserves: '$needle'"
        else
            fail "$id" "outline SKILL.md MUST preserve: '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 6. Preserved instructions (detail)
# ---------------------------------------------------------------------------
echo "=== make-detail-plan: preserved instructions ==="
if require_file "REQFILE-make-detail-plan" "$DETAIL_SKILL"; then
    for entry in \
        "C6-detail-preserve-read-intent-outline|Read intent/outline before planning" \
        "C6-detail-preserve-follow-core-principles|Follow \`rules/core-principles.md\`" \
        "C6-detail-preserve-one-confirmation-per-run|One user-facing confirmation per run"
    do
        id="${entry%%|*}"
        needle="${entry#*|}"
        if has_fixed "$needle" "$DETAIL_SKILL"; then
            pass "$id" "detail SKILL.md preserves: '$needle'"
        else
            fail "$id" "detail SKILL.md MUST preserve: '$needle'"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 7. worktree-start WS-2 must NOT use AskUserQuestion
# ---------------------------------------------------------------------------
# Inverted by #1910: WS-2 (task name / branch type) used to be an interactive
# confirmation step, and this check pinned the AskUserQuestion call that made it
# one. The naming step is now fully automatic, and the only surviving mentions of
# AskUserQuestion in that section are prohibitions — so a bare presence check
# would pass on text asserting the exact opposite of its original intent. Pin the
# prohibition itself instead.
echo "=== worktree-start: AskUserQuestion prohibited for WS-2 naming ==="
if require_file "REQFILE-worktree-start" "$WORKTREE_SKILL"; then
    if has_fixed 'Never call `AskUserQuestion` to choose a task name or branch type' "$WORKTREE_SKILL"; then
        pass "C7-worktree-askuserquestion-prohibited" "worktree-start/SKILL.md prohibits AskUserQuestion for task name / branch type"
    else
        fail "C7-worktree-askuserquestion-prohibited" "worktree-start/SKILL.md MUST prohibit AskUserQuestion for task name / branch type (#1910)"
    fi
fi

# ---------------------------------------------------------------------------
# 8. .env.example has all 6 CONFIRM_* keys
# ---------------------------------------------------------------------------
echo "=== .env.example: all CONFIRM_* keys present ==="
if require_file "REQFILE-env-example" "$ENV_EXAMPLE"; then
    for key in CONFIRM_OUTLINE CONFIRM_DETAIL CONFIRM_TESTS CONFIRM_WORKTREE CONFIRM_CODE CONFIRM_DOCS; do
        id="C8-$(printf '%s' "$key" | tr '_' '-')"
        # Match `KEY=` at start of line (allow leading whitespace)
        if grep -E "^[[:space:]]*${key}=" "$ENV_EXAMPLE" >/dev/null 2>&1; then
            pass "$id" ".env.example defines $key"
        else
            fail "$id" ".env.example missing $key (expected '$key=...')"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 9. The get-config-var PATH-exposure contract is delegated, and alive (#1967)
# ---------------------------------------------------------------------------
# This section does NOT re-assert the fact that `get-config-var` is on the shared
# list. That fact's owner is T8 in tests/install-path-exposed-commands.sh, which
# reads install/path-exposed-commands.txt directly (CPR-SSOT); a copy here would be
# a second, driftable transcription of exactly what #1967 was about.

# The owner test is not EXECUTED from here either: it takes a measured 348-460 s,
# far past the 120 s default in rules/test.md. What is pinned instead is that the
# delegate is still defined, still on the owner's run list (not dormant), and still
# looking at `get-config-var` -- so a silently deleted or hollowed-out T8 shows up
# here as well, which is the failure mode #1967 itself was.

# Nor is a negative control needed HERE for the fact itself. "T8's predicate has not
# degenerated into something that answers yes unconditionally" is proven on every run
# of the owner test by T8b, whose rows feed the same predicate a list with the entry
# removed, an empty list, and a missing list file. Re-proving it here would mean a
# second transcription of the same claim, which is the shape of the drift #1967 was
# (CPR-SSOT). C9-d is what keeps that control itself from going dormant.
echo "=== get-config-var PATH exposure: delegated to tests/install-path-exposed-commands.sh ==="
UNOWNED="the get-config-var PATH exposure contract has become unowned (#1967)"
if require_file "REQFILE-owner-test" "$OWNER_TEST"; then
    if grep -qE '^t8_get_config_var_pinned\(\)' "$OWNER_TEST"; then
        pass "C9-a" "the owner test defines t8_get_config_var_pinned()"
    else
        fail "C9-a" "the owner test no longer defines t8_get_config_var_pinned() -- $UNOWNED"
    fi
    # Bare name, line start, no arguments: the only call form the owner test's run
    # list uses, and distinguishable from the definition line (which is followed by
    # `()`) and from any mention inside a comment or a string.
    if grep -qE '^t8_get_config_var_pinned[[:space:]]*$' "$OWNER_TEST"; then
        pass "C9-b" "t8_get_config_var_pinned is on the owner test's run list"
    else
        fail "C9-b" "t8_get_config_var_pinned is defined but never invoked (dormant) -- $UNOWNED"
    fi
    body="$(sed -n '/^t8_get_config_var_pinned()/,/^}/p' "$OWNER_TEST")"
    if printf '%s\n' "$body" | grep -qF -- "get-config-var" \
        && printf '%s\n' "$body" | grep -qF -- "pinned_in_list"; then
        pass "C9-c" "t8_get_config_var_pinned still checks get-config-var through pinned_in_list"
    else
        fail "C9-c" "t8_get_config_var_pinned no longer names get-config-var / pinned_in_list -- $UNOWNED"
    fi
    if grep -qE '^t8b_pin_negative_control[[:space:]]*$' "$OWNER_TEST"; then
        pass "C9-d" "the negative control t8b_pin_negative_control is on the owner test's run list"
    else
        fail "C9-d" "t8b_pin_negative_control is not on the owner test's run list, so T8's predicate is no longer proven non-vacuous -- $UNOWNED"
    fi
    # C9-d only proves the control is CALLED. The owner test runs under `set -uo
    # pipefail` with no `-e`, so calling a function whose definition was deleted is
    # a `command not found` that neither aborts the run nor touches its FAIL
    # counter: the control would be gone and the owner test would still exit 0.
    # C9-a is the same assertion for T8 itself; this is its CPR-ORTH counterpart.
    if grep -qE '^t8b_pin_negative_control\(\)' "$OWNER_TEST"; then
        pass "C9-e" "the owner test defines t8b_pin_negative_control()"
    else
        fail "C9-e" "t8b_pin_negative_control is invoked but no longer DEFINED -- with no set -e the call is a silent 'command not found' and the negative control is dead -- $UNOWNED"
    fi
    # C9-c matches strings, and a comment carries strings just as well as code does:
    # commenting the delegate's `check` line out leaves both needles in place while
    # T8 executes zero assertions. Require at least one assertion call that is not
    # commented out.
    if printf '%s\n' "$body" | grep -qE '^[[:space:]]*check[[:space:]]'; then
        pass "C9-f" "t8_get_config_var_pinned still executes a check call (not merely a comment naming one)"
    else
        fail "C9-f" "t8_get_config_var_pinned contains no executable check call -- its assertions have been commented out or removed while the matched strings survive -- $UNOWNED"
    fi
    # C9-a..C9-f all match STRINGS. An empty case table, or an early `return` in front of
    # the loop, leaves every one of those strings on the page while T8 executes zero rows --
    # the shape no grep from here can see. The owner test carries its own executed-row
    # budget (t8c_row_budget) for exactly that; these two rows keep the budget from being
    # deleted or unhooked, the same way C9-a/C9-b do for the delegate itself. Proof that the
    # budget actually FIRES on an empty or unreachable loop is the M5 group of
    # tests/fix-1967-c9-delegation-mutation.sh, which executes it against a mutated copy.
    if grep -qE '^t8c_row_budget\(\)' "$OWNER_TEST"; then
        pass "C9-g" "the owner test defines t8c_row_budget(), the executed-row budget for T8/T8b"
    else
        fail "C9-g" "the owner test no longer defines t8c_row_budget() -- an empty or unreachable T8 case table would execute zero assertions and still report green -- $UNOWNED"
    fi
    if grep -qE '^t8c_row_budget[[:space:]]*$' "$OWNER_TEST"; then
        pass "C9-h" "t8c_row_budget is on the owner test's run list"
    else
        fail "C9-h" "t8c_row_budget is defined but never invoked (dormant), so the executed-row budget guards nothing -- $UNOWNED"
    fi
fi

# ---------------------------------------------------------------------------
# 10. Post-action CONFIRM_* gates (#425, #472)
# ---------------------------------------------------------------------------
echo "=== 10. Post-action CONFIRM_* gates (#425, #472) ==="
if require_file "REQFILE-write-tests" "$TESTS_SKILL"; then
    hit=$(awk '/Present the final test file content/{a=NR} a && NR>=a-8 && NR<=a+8 && /CONFIRM_TESTS/{print NR; exit}' "$TESTS_SKILL")
    if [ -n "$hit" ]; then
        pass "C10-write-tests-gate" "write-tests step 7 has CONFIRM_TESTS gate (line $hit)"
    else
        fail "C10-write-tests-gate" "write-tests step 7 missing CONFIRM_TESTS gate near 'Present the final test file'"
    fi
fi
if require_file "REQFILE-write-code" "$WRITE_CODE_SKILL"; then
    hit=$(awk '/Present the final edited file list/{a=NR} a && NR>=a-8 && NR<=a+8 && /CONFIRM_CODE/{print NR; exit}' "$WRITE_CODE_SKILL")
    if [ -n "$hit" ]; then
        pass "C10-write-code-gate" "write-code step 6 has CONFIRM_CODE gate (line $hit)"
    else
        fail "C10-write-code-gate" "write-code step 6 missing CONFIRM_CODE gate near 'Present the final edited file list'"
    fi
fi

# ---------------------------------------------------------------------------
# Accounting. A ledger entry that no check site reports any more is as bad as an
# unexpected failure: it means the ledger is describing a check that no longer
# exists, and the next reader would trust a number that measures nothing.
# ---------------------------------------------------------------------------
echo
for ledger_id in $(ledger_ids); do
    if ! printf '%s\n' "$OBSERVED_IDS" | grep -qx -- "$ledger_id"; then
        echo "STALE-LEDGER: [$ledger_id] no check site reported this id"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
done

echo "Total: $PASSED passed, $XFAIL expected-fail (known RED, tracked in #2054), $UNEXPECTED unexpected"
if [ "$UNEXPECTED" -eq 0 ]; then
    echo "All checks accounted for ($XFAIL known RED, 0 unexpected)."
    exit 0
else
    echo "$UNEXPECTED unexpected result(s) -- see FAIL / XPASS / STALE-LEDGER lines above."
    exit 1
fi
