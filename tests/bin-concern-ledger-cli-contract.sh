#!/usr/bin/env bash
# tests/bin-concern-ledger-cli-contract.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, cli, edge-cases, error-cases, config-branch, sha-tool, table-driven, scope:common, pwsh-not-required
#
# Two test-design categories that the rest of this suite leaves uncovered, kept
# together because they share one question: what does the CLI do when the values
# it is handed are legal-looking but wrong?

# The first half is the argument surface. Every subcommand takes a round, a cap
# and a set of paths, and a caller that computes one of them wrongly — an empty
# variable, an off-by-one, a report file that was never written — must be told
# so. The failure to avoid is a CLI that accepts 'round 0' or a missing report
# and reports success, because the orchestrator above it reads that success as
# "this round was reviewed".

# The second half is the one configuration branch in the library:
# CL_SHA_TOOL picks among four digest backends. SLOT is the identity a concern
# is tracked by across rounds, so a backend that yields a different digest — or
# an uppercase one — silently makes every concern new again.

# TL2. The real bin/concern-ledger over real files in a throwaway sandbox.

# TL3 gap (mitigation category: environment)
#   Not covered here: a host on which sha256sum/shasum/openssl genuinely are
#   absent. Case 4 forces each backend by pinning CL_SHA_TOOL, which exercises
#   the selected branch but not the auto-detection ladder's fallthrough.
#   Mitigation: the cksum branch — the ladder's last resort, and the only one
#   reached on a bare host — is pinned explicitly alongside the others.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0

# Cases 1-3 are known gaps in the same argument-validation family #2032 already
# tracks. Sourced after FAIL exists, which the helpers increment on an XPASS.
# shellcheck source=./lib/xfail.sh
. "$AGENTS_ROOT/tests/lib/xfail.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CL_SHA_TOOL 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

for _f in "$CLI" "$LIB"; do
    if [ ! -f "$_f" ]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        echo "FAIL: implementation missing: ${_f#"$AGENTS_ROOT/"}"
        FAIL=$((FAIL + 1))
    fi
done

FORMAT="cli-contract"
PLANS="$TMPDIR_BASE/plans-ok"
mkdir -p "$PLANS"
SID="clc1"

REPORT="$TMPDIR_BASE/report.txt"
{
    printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
    printf -- '- [HIGH] - | a/b.sh#fn | correctness | an ordinary concern\n'
    printf '\n'
} > "$REPORT"

EMPTY_REPORT="$TMPDIR_BASE/empty-report.txt"
: > "$EMPTY_REPORT"
MISSING_REPORT="$TMPDIR_BASE/nowhere/absent-report.txt"

# verdict <rc> — 'rejected' or 'accepted'. A named verdict rather than a number,
# so a table row states the contract instead of restating the implementation.
verdict() { [ "$1" -ne 0 ] && printf 'rejected' || printf 'accepted'; }

# ---------------------------------------------------------------------------
# 1. The round argument. It indexes a filename and gates admission, so every
#    value that is not a positive integer has to be refused rather than pasted
#    into a path. Includes the boundary the vocabulary does allow (1).
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 1: the --round argument ---"

stage_round() {
    local rc=0
    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round "$1" --producer review-code-codex --from-report "$REPORT" \
        >/dev/null 2>&1 || rc=$?
    verdict "$rc"
}

while IFS='~' read -r VAL WANT PIN; do
    VAL="${VAL%"${VAL##*[![:space:]]}"}"
    WANT="${WANT#"${WANT%%[![:space:]]*}"}"; WANT="${WANT%"${WANT##*[![:space:]]}"}"
    PIN="${PIN#"${PIN%%[![:space:]]*}"}"; PIN="${PIN%"${PIN##*[![:space:]]}"}"
    [ -n "$WANT" ] || continue
    case "$VAL" in \#*) continue ;; esac
    if [ "$PIN" = "pinned" ]; then
        xfail_eq "1: --round '$VAL' is $WANT" "$WANT" "$(stage_round "$VAL")"
    else
        assert_eq "1: --round '$VAL' is $WANT" "$WANT" "$(stage_round "$VAL")"
    fi
done <<'ROUNDS'
1~accepted~ok
0~rejected~pinned
-1~rejected~pinned
1.5~rejected~pinned
one~rejected~pinned
 ~rejected~ok
2x~rejected~pinned
99999999999999999999~rejected~pinned
ROUNDS

# ---------------------------------------------------------------------------
# 2. The report path. A report that does not exist and a report that exists but
#    is empty are different failures and must not collapse into one: the first
#    is a caller bug, the second is a reviewer that produced nothing. Neither
#    may look like a completed stage.
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 2: the --from-report path ---"

stage_report() {
    local rc=0
    bash "$CLI" stage --plans-dir "$TMPDIR_BASE/plans-rp-$2" --session-id "$SID" \
        --format "$FORMAT" --round 1 --producer review-code-codex \
        --from-report "$1" >/dev/null 2>&1 || rc=$?
    verdict "$rc"
}
mkdir -p "$TMPDIR_BASE/plans-rp-a" "$TMPDIR_BASE/plans-rp-b" "$TMPDIR_BASE/plans-rp-c"

xfail_eq "2: a report path that does not exist is rejected" \
    "rejected" "$(stage_report "$MISSING_REPORT" a)"
xfail_eq "2: an empty report is rejected rather than staged as a silent no-op" \
    "rejected" "$(stage_report "$EMPTY_REPORT" b)"
assert_eq "2: and a real report on the same code path still stages" \
    "accepted" "$(stage_report "$REPORT" c)"

# ---------------------------------------------------------------------------
# 3. Subcommand and required-option selection. An unknown subcommand and a flag
#    whose value went missing are the two ways a caller's own typo arrives here.
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 3: subcommand and required-option selection ---"

assert_eq "3: an unknown subcommand is rejected" "rejected" \
    "$(bash "$CLI" nosuchthing >/dev/null 2>&1; verdict "$?")"
assert_eq "3: no subcommand at all is rejected" "rejected" \
    "$(bash "$CLI" >/dev/null 2>&1; verdict "$?")"
assert_eq "3: an unknown option is rejected" "rejected" \
    "$(bash "$CLI" tally --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FORMAT" --nonsense >/dev/null 2>&1; verdict "$?")"
xfail_eq "3: a required option left empty is rejected, not defaulted" "rejected" \
    "$(bash "$CLI" tally --plans-dir "$PLANS" --session-id "" \
        --format "$FORMAT" >/dev/null 2>&1; verdict "$?")"
assert_eq "3: check-finalized on a session with no artifact is rejected" "rejected" \
    "$(bash "$CLI" check-finalized --plans-dir "$TMPDIR_BASE/plans-none" \
        --session-id nobody --format "$FORMAT" >/dev/null 2>&1; verdict "$?")"

# ---------------------------------------------------------------------------
# 4. CL_SHA_TOOL. SLOT is the address a concern keeps across rounds, so the
#    digest backend is a config-dependent branch in the strict sense: pick the
#    wrong one and every concern is re-filed under a new address next round.
# ---------------------------------------------------------------------------

# Two properties, deliberately separate (CPR-SC). Within one backend the digest
# must be stable and lowercase hex — that is what makes SLOT usable as a key at
# all. Across backends the digests may legitimately differ, since they are
# different hash functions; what must NOT differ is whether two distinct
# concerns collide.
echo ""
echo "--- cli 4: the CL_SHA_TOOL digest backend ---"

slot_with() {
    CL_SHA_TOOL="$1" bash "$CLI" slot --path "$2" --anchor "$3" --category "$4" 2>/dev/null
}

for TOOL in sha256sum shasum openssl cksum; do
    if [ "$TOOL" != "cksum" ] && ! command -v "$TOOL" >/dev/null 2>&1; then
        # Absent backends are the point of the ladder, so this is a real result,
        # not a skip: the CLI must still answer, having fallen back.
        FB="$(slot_with "$TOOL" "bin/x.sh" "fn" "security")"
        assert_eq "4: $TOOL is unavailable here, and the CLI still yields a slot" \
            "ok" "$([ -n "$FB" ] && printf ok || printf empty)"
        continue
    fi

    S1="$(slot_with "$TOOL" "bin/x.sh" "fn" "security")"
    S2="$(slot_with "$TOOL" "bin/x.sh" "fn" "security")"
    OTHER="$(slot_with "$TOOL" "bin/y.sh" "fn" "security")"

    assert_eq "4 ($TOOL): the slot is 8 lowercase hex digits" "ok" \
        "$(printf '%s' "$S1" | grep -Eq '^[0-9a-f]{8}$' && printf ok || printf "bad:$S1")"
    assert_eq "4 ($TOOL): the same address hashes the same way twice" "$S1" "$S2"
    assert_eq "4 ($TOOL): and two different addresses do not collide" \
        "distinct" "$([ "$S1" != "$OTHER" ] && printf distinct || printf collided)"
done

# The cache is an optimisation, so it must be invisible: a repeated address
# inside one process has to give the same answer as a cold one.
CACHE_HOT="$(CL_SHA_TOOL=cksum bash -c '
    source "$1" >/dev/null 2>&1 || exit 1
    a="$(cl_slot bin/x.sh fn security)"
    b="$(cl_slot bin/z.sh fn security)"
    c="$(cl_slot bin/x.sh fn security)"
    [ "$a" = "$c" ] && [ "$a" != "$b" ] && printf consistent || printf poisoned
' _ "$LIB" 2>/dev/null)"
assert_eq "4: the in-process digest cache returns the value it stored, not a neighbour's" \
    "consistent" "$CACHE_HOT"

# An unrecognised CL_SHA_TOOL value must land on the documented fallback rather
# than producing an empty slot, which would make every concern share one address.
BOGUS="$(slot_with "not-a-real-tool" "bin/x.sh" "fn" "security")"
assert_eq "4: an unrecognised CL_SHA_TOOL still yields a well-formed slot" "ok" \
    "$(printf '%s' "$BOGUS" | grep -Eq '^[0-9a-f]{8}$' && printf ok || printf "bad:$BOGUS")"
assert_eq "4: and it is the documented cksum fallback, not a fifth behaviour" \
    "$(slot_with cksum "bin/x.sh" "fn" "security")" "$BOGUS"

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
