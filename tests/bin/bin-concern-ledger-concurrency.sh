#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-concurrency.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, concurrency, atomic-write, shared-ledger, lost-update, scope:common, pwsh-not-required
#
# Two producers (review-code-codex, security-scanner) stage the same round at once
# by design; properties: no lost delta, no torn artifact, no leftover temp (CPR-SC).
# TL2: real CLI subprocesses, backgrounded and joined — no mocks.
set -uo pipefail

# TL3 gap (mitigation category: environment): the scheduler decides how much the
# background jobs overlap, so a lost-update window narrower than process startup
# stays invisible. Mitigation: case 1 repeats the race so a wide window fails reliably.

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"

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

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

if [ ! -f "$CLI" ]; then
    echo "SKIP-BLOCKED: bin/concern-ledger not implemented yet"
    echo "FAIL: implementation missing"
    exit 1
fi

FORMAT="cl-race"
PRODUCERS="review-code-codex security-scanner"

# mk_report <file> <text> — a one-concern report anchored somewhere unique, so
# each producer's finding has its own SLOT and none can mask another.
mk_report() {
    {
        printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
        printf -- '- [HIGH] - | bin/%s.sh#fn | correctness | %s\n' "$3" "$2"
        printf '\n'
    } > "$1"
}

# ---------------------------------------------------------------------------
# 1. Two producers staging the same round at the same time. Repeated, because a
#    race that only sometimes loses a write is still a race.
# ---------------------------------------------------------------------------
echo ""
echo "--- concurrency 1: simultaneous staging by both producers ---"

LOST=0
TORN=0
for ITER in 1 2 3 4 5; do
    PLANS="$TMPDIR_BASE/race-$ITER"
    SID="race$ITER"
    mkdir -p "$PLANS"

    for P in $PRODUCERS; do
        mk_report "$PLANS/report-$P.txt" "a concern from $P in iteration $ITER" "$P"
    done

    for P in $PRODUCERS; do
        bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
            --round 1 --producer "$P" --from-report "$PLANS/report-$P.txt" \
            >/dev/null 2>&1 &
    done
    wait

    # #2434: control files live in <WORKFLOW_STATE_DIR>/<sid>.control, unprefixed.
    CTL="$WORKFLOW_STATE_DIR/$SID.control"
    for P in $PRODUCERS; do
        D="$CTL/$FORMAT-round-1-delta-$P.txt"
        if ! grep -Fq -- "a concern from $P in iteration $ITER" "$D" 2>/dev/null; then
            LOST=$((LOST + 1))
        fi
    done

    # Fold the concurrently-written deltas, then read the ledger back. A torn
    # write shows up as a row that no longer has its 11 fields.
    bash "$CLI" reduce --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round 1 >/dev/null 2>&1
    LED="$CTL/$FORMAT-concern-ledger.txt"
    BAD="$(awk -F'|' '/^#/ { next } NF > 0 && NF != 11 { n++ } END { printf "%d", n + 0 }' \
        "$LED" 2>/dev/null)"
    [ "$BAD" = "0" ] || TORN=$((TORN + 1))

    ROWS="$(awk -F'|' '/^#/ { next } NF == 11 { n++ } END { printf "%d", n + 0 }' "$LED" 2>/dev/null)"
    assert_eq "1 (iteration $ITER): both producers' concerns are in the folded ledger" \
        "2" "$ROWS"
done

assert_eq "1: no producer's delta was lost across the repeated race" "0" "$LOST"
assert_eq "1: and no fold left a malformed row behind" "0" "$TORN"

# ---------------------------------------------------------------------------
# 2. Overlapping finalize. Two writers racing for one artifact path is the case
#    where a partial read is worst: the artifact is what the verdict is read
#    from, so a half-written one is a verdict decided on a truncated file.
# ---------------------------------------------------------------------------
echo ""
echo "--- concurrency 2: overlapping finalize on one artifact ---"

FPLANS="$TMPDIR_BASE/fin-race"
FSID="finrace"
mkdir -p "$FPLANS"
mk_report "$FPLANS/r.txt" "a concern the artifact must carry" "one"
bash "$CLI" stage --plans-dir "$FPLANS" --session-id "$FSID" --format "$FORMAT" \
    --round 1 --producer review-code-codex --from-report "$FPLANS/r.txt" >/dev/null 2>&1
bash "$CLI" reduce --plans-dir "$FPLANS" --session-id "$FSID" --format "$FORMAT" \
    --round 1 >/dev/null 2>&1

for _ in 1 2 3; do
    bash "$CLI" finalize --plans-dir "$FPLANS" --session-id "$FSID" --format "$FORMAT" \
        --mode LAND --reason 'cap reached' --round 1 --cap 1 >/dev/null 2>&1 &
done
wait

FCTL="$WORKFLOW_STATE_DIR/$FSID.control"
FJSON="$FCTL/$FORMAT-unresolved-concerns.json"
assert_eq "2: the racing finalizers left exactly one artifact" \
    "1" "$(find "$FCTL" -maxdepth 1 -name "$FORMAT-unresolved-concerns.json" 2>/dev/null | wc -l | tr -d ' ')"

# The artifact a real parser accepts is the only definition of "not torn".
if command -v node >/dev/null 2>&1; then
    PARSE="$(node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write("valid")' \
        "$FJSON" 2>/dev/null || printf 'invalid')"
else
    PARSE="$(python3 -c 'import json,sys;json.load(open(sys.argv[1]));sys.stdout.write("valid")' \
        "$FJSON" 2>/dev/null || printf 'invalid')"
fi
assert_eq "2: and that artifact is whole — a real JSON parser accepts it" "valid" "$PARSE"
assert_eq "2: carrying the concern it was finalized for" "present" \
    "$(grep -Fq -- "a concern the artifact must carry" "$FJSON" 2>/dev/null && printf present || printf absent)"
assert_eq "2: and check-finalized accepts the round the race finished" "0" \
    "$(bash "$CLI" check-finalized --plans-dir "$FPLANS" --session-id "$FSID" \
        --format "$FORMAT" --round 1 >/dev/null 2>&1; printf '%s' "$?")"

# ---------------------------------------------------------------------------
# 3. Temp-file hygiene. An atomic write stages through a temp name and renames;
#    if any of the racing writers leaves its scratch file behind, the plans dir
#    accumulates partial ledgers that later globs can pick up.
# ---------------------------------------------------------------------------
echo ""
echo "--- concurrency 3: no scratch files survive the race ---"

STRAY="$(find "$FPLANS" "$TMPDIR_BASE/race-1" "$FCTL" "$WORKFLOW_STATE_DIR/race1.control" -maxdepth 1 \
    \( -name '*.tmp' -o -name '*.tmp.*' -o -name '.*.swp' -o -name '*~' -o -name '*.partial' \) \
    2>/dev/null | wc -l | tr -d ' ')"
assert_eq "3: the racing writers left no scratch files in the plans dirs" "0" "$STRAY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
