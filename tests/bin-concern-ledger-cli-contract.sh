#!/usr/bin/env bash
# tests/bin-concern-ledger-cli-contract.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, cli, edge-cases, error-cases, config-branch, sha-tool, table-driven, scope:common, pwsh-not-required
#
# What does the CLI do when its arguments are legal-looking but wrong? One that
# accepts 'round 0' or a missing report and reports success is read by the
# orchestrator above it as "this round was reviewed". Second half: CL_SHA_TOOL,
# where SLOT is the address a concern keeps across rounds, so a backend yielding
# a different digest re-files every concern. TL2, real CLI in a sandbox; TL3 gap
# (environment) is a host lacking sha256sum, mitigated by pinning cksum.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0

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

# assert_eq with a guard: an expectation that could not be computed is itself a
# failure, so '' == '' can never pass while the thing under test is missing.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
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
    # The third column used to mark rows as known gaps (#2057). Every row is a
    # requirement now, so a row that still says otherwise is itself a failure.
    if [ "$PIN" != "ok" ]; then
        echo "FAIL: 1: --round '$VAL' is still marked '$PIN' rather than a requirement"
        FAIL=$((FAIL + 1))
    else
        assert_eq "1: --round '$VAL' is $WANT" "$WANT" "$(stage_round "$VAL")"
    fi
done <<'ROUNDS'
1~accepted~ok
0~rejected~ok
-1~rejected~ok
1.5~rejected~ok
one~rejected~ok
 ~rejected~ok
2x~rejected~ok
99999999999999999999~rejected~ok
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

assert_eq "2: a report path that does not exist is rejected" \
    "rejected" "$(stage_report "$MISSING_REPORT" a)"
assert_eq "2: an empty report is rejected rather than staged as a silent no-op" \
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
assert_eq "3: a required option left empty is rejected, not defaulted" "rejected" \
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

# ---------------------------------------------------------------------------
# 5. The empty report has exactly one legitimate answer. Rejecting empties is
#    only a universal rule if there is no flag that suspends it: a caller with
#    nothing open must say so in the report rather than send an empty file and
#    ask the CLI to accept it (CPR-UNV).
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 5: the one legitimate way to stage a round with nothing open ---"

assert_eq "5: the CLI offers no public option for accepting an empty report" \
    "absent" "$(grep -Fq 'allow-empty' "$CLI" && printf present || printf absent)"

SENTINEL_REPORT="$TMPDIR_BASE/sentinel-report.txt"
{
    printf '## Review: PERFORMED\n\n'
    printf '<!-- concern-ledger: no open concerns in round 1 -->\n'
} > "$SENTINEL_REPORT"
SENT_PLANS="$TMPDIR_BASE/plans-sentinel"
mkdir -p "$SENT_PLANS"
SENT_RC=0
bash "$CLI" stage --plans-dir "$SENT_PLANS" --session-id sent1 --format "$FORMAT" \
    --round 1 --producer review-code-codex --from-report "$SENTINEL_REPORT" \
    >/dev/null 2>&1 || SENT_RC=$?
SENT_DELTA="$SENT_PLANS/sent1-$FORMAT-round-1-delta-review-code-codex.txt"

assert_eq "5: a report that states nothing is open is accepted" "0" "$SENT_RC"
assert_eq "5: and the round it staged is on disk like any other" \
    "present" "$([ -f "$SENT_DELTA" ] && printf present || printf missing)"
assert_eq "5: carrying no concern records, since none were open to carry" \
    "0" "$(grep -cvE '^#|^$' "$SENT_DELTA" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
# 6. check-staged has to be reachable before it can be a gate: close-concern-
#    round.sh calls it on itself, so an unregistered subcommand would make the
#    gate fail on every round for the wrong reason. Then the gate's own point —
#    a delta exists, but the producer it names never reviewed anything.
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 6: check-staged is dispatched, and judges completeness ---"

CS_PLANS="$TMPDIR_BASE/plans-checkstaged"
mkdir -p "$CS_PLANS"
CS_REPORT="$TMPDIR_BASE/cs-report.txt"
printf '## Review: SKIPPED\n' > "$CS_REPORT"
bash "$CLI" stage --plans-dir "$CS_PLANS" --session-id cs1 --format "$FORMAT" \
    --round 1 --producer review-code-codex --exec SKIPPED --from-report "$CS_REPORT" \
    >/dev/null 2>&1 || true

CS_OUT="$(bash "$CLI" check-staged --plans-dir "$CS_PLANS" --session-id cs1 \
    --format "$FORMAT" --round 1 2>/dev/null)"
CS_RC=$?

assert_eq "6: check-staged is a real subcommand, not a usage error" \
    "dispatched" "$([ "$CS_RC" -eq 0 ] || [ "$CS_RC" -eq 1 ] && printf dispatched || printf "usage:$CS_RC")"
assert_eq "6: a round whose only producer skipped its review is not complete" "1" "$CS_RC"
assert_eq "6: and the reason names the completeness it found, not just 'missing'" \
    "found" "$(printf '%s' "$CS_OUT" | grep -Fq 'incomplete:ABSENT' && printf found || printf "got:$CS_OUT")"

# 7. #2088 at the CLI boundary. This case is green before the fix as well as
#    after it: its job is to give the backslash plans dir an execution path
#    through a real subcommand, so a later change to path handling cannot
#    quietly stop working on Windows-spelled directories.
# ---------------------------------------------------------------------------
echo ""
echo "--- cli 7: check-staged finds staged deltas through a backslash plans dir ---"

# The no-producer branch is one of the two MUST class members for #2088 (the
# other is bin/lib/concern-ledger/reduce.sh's cl_reduce). Every case below
# already passes on the pre-fix raw glob — bash globs tolerate a backslash the
# way #2088's compgen -G did not — so a revert is caught not here but in
# tests/bin-concern-ledger-cli-contract/check-staged-discovery.sh, sourced
# below, which pins the subcommand body against reverted mutants of it.

# bs_plans <base> — a plans dir reachable through a path holding a backslash. On
# Windows that is cygpath -w of a real directory (the shape #2088 was reported
# in); elsewhere a backslash is a legal filename character, so one goes into the
# name. Constructible on every platform, so this case never skips.
bs_plans() {
    local base="$1" d
    if command -v cygpath >/dev/null 2>&1; then
        d="$base/plansdir"; mkdir -p "$d"; cygpath -w "$d"
    else
        d="$base/plans\\evil"; mkdir -p "$d"; printf '%s' "$d"
    fi
}

# cs_stage <plans> <sid> <round> <producer> <exec> — one staged delta.
cs_stage() {
    bash "$CLI" stage --plans-dir "$1" --session-id "$2" --format "$FORMAT" \
        --round "$3" --producer "$4" --exec "$5" --from-report "$REPORT" >/dev/null 2>&1
}

# cs_check <plans> <sid> <round> → "rc=<n> out=<stdout>"
cs_check() {
    local out rc
    out="$(bash "$CLI" check-staged --plans-dir "$1" --session-id "$2" \
        --format "$FORMAT" --round "$3" 2>/dev/null)"
    rc=$?
    printf 'rc=%s out=%s' "$rc" "$out"
}

BS="$(bs_plans "$TMPDIR_BASE/bs")"
assert_eq "7: the fixture really is a backslash-bearing plans dir (precondition)" \
    "has-backslash" \
    "$(case "$BS" in *\\*) printf has-backslash ;; *) printf 'no-backslash:%s' "$BS" ;; esac)"

# FORMAT declares no producers, so check-staged takes the branch that scans the
# plans dir with a glob — the one #2088 degrades.
assert_eq_nz "7: with no producers declared, check-staged takes the plans-dir scan branch" \
    "none-declared" \
    "$([ -z "$(bash -c 'set +u; source "$0" >/dev/null 2>&1; cl_declared_producers "$1"' \
        "$LIB" "$FORMAT" 2>/dev/null)" ] && printf none-declared || printf declared)"

cs_stage "$BS" bs1 1 review-code-codex PERFORMED
BS1="$(cs_check "$BS" bs1 1)"
assert_eq_nz "7: a COMPLETE delta is found through the backslash path" "rc=0 out=" "$BS1"

cs_stage "$BS" bs2 1 review-code-codex SKIPPED
BS2="$(cs_check "$BS" bs2 1)"
assert_eq "7: an incomplete delta is reported as incomplete, not as missing" \
    "rc=1 reason=incomplete" \
    "$(printf '%s' "$BS2" | grep -Fq 'incomplete:' && printf 'rc=1 reason=incomplete' || printf '%s' "$BS2")"

BS3="$(cs_check "$BS" bs3 1)"
assert_eq_nz "7: a round with nothing staged is missing, through the backslash path too" \
    "rc=1 out=(no format):missing" "$BS3"

# Two producers, one incomplete and one COMPLETE: the scan must keep looking
# after the incomplete one instead of stopping at it.
cs_stage "$BS" bs4 1 security-scanner SKIPPED
cs_stage "$BS" bs4 1 review-code-codex PERFORMED
assert_eq_nz "7: one COMPLETE producer is enough even when a sibling is incomplete" \
    "rc=0 out=" "$(cs_check "$BS" bs4 1)"

# A delta staged for a different round must not satisfy this round.
cs_stage "$BS" bs5 2 review-code-codex PERFORMED
assert_eq_nz "7: a delta from another round does not satisfy this one" \
    "rc=1 out=(no format):missing" "$(cs_check "$BS" bs5 1)"

# Parity: the ordinary spelling must give byte-identical answers. Asserted after
# the backslash results are already computed, so the comparison pins agreement
# rather than restating one side.
OKP="$TMPDIR_BASE/plans-ok-spelled"
mkdir -p "$OKP"
cs_stage "$OKP" ok1 1 review-code-codex PERFORMED
assert_eq_nz "7: the ordinary spelling answers the COMPLETE case identically" \
    "$(cs_check "$OKP" ok1 1)" "$BS1"
cs_stage "$OKP" ok2 1 review-code-codex SKIPPED
assert_eq_nz "7: and the incomplete case identically" \
    "$(cs_check "$OKP" ok2 1)" "$(printf '%s' "$BS2" | sed 's/bs2/ok2/')"

# shellcheck source=./bin-concern-ledger-cli-contract/check-staged-discovery.sh
. "$AGENTS_ROOT/tests/bin-concern-ledger-cli-contract/check-staged-discovery.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
