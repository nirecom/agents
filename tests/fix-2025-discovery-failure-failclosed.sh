#!/usr/bin/env bash
# tests/fix-2025-discovery-failure-failclosed.sh
# Tests: bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh, bin/concern-ledger
# Tags: concern-ledger, discovery, fail-closed, silent-loss, mechanism-failure, security, scope:issue-specific, pwsh-not-required
#
# Three subcommands find this round's staging files with one helper, which used
# to swallow its own mechanism: `find ... 2>/dev/null`, no status check, an
# unconditional `return 0`. A failing find was indistinguishable from an empty
# directory, so each caller reported a clean result for a round it never read
# (#2025 C6). The helper now propagates that status and every caller refuses:
# one injected failure, three surfaces, against a control proving it worked.
set -uo pipefail

# TL2. The real bin/concern-ledger runs against real staged deltas in a sandbox;
# the failure is injected by shadowing `find` on PATH, which is the mechanism the
# helper depends on rather than a rewritten copy of it.

# TL3 gap (mitigation category: filesystem-semantics)
#   Not covered here: the failures a real host produces — an NFS stall, a
#   permission-denied on one entry of a readable directory, a path over the
#   Windows MAX_PATH limit. Each surfaces as a different find status or partial
#   output, and none is reproducible below TL3.
#   Mitigation: the assertion is on the caller's verdict, not on find's message,
#   so any non-zero mechanism status is the same case.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# An expectation that could not be computed is itself a failure, so '' == ''
# can never pass while the fixture is broken.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
    if printf '%s' "$3" | grep -Fq -- "$2"; then
        pass "$1"
    else
        echo "FAIL: $1 — expected output to contain $(printf '%q' "$2")"
        FAIL=$((FAIL + 1))
    fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-root"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

SID="sess-c6"
FMT="review-security-shared"

REPORT="$TMPDIR_BASE/report.txt"
{
    printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
    printf -- '- [HIGH] - | a/b.sh#fn | correctness | the round-two finding\n\n'
} > "$REPORT"

# The injected mechanism failure: `find` on PATH exits non-zero with a
# diagnostic, exactly as it would on an unreadable or vanished directory.
STUB="$TMPDIR_BASE/stub"
mkdir -p "$STUB"
cat > "$STUB/find" <<'EOF'
#!/usr/bin/env bash
echo "find: simulated mechanism failure" >&2
exit 1
EOF
chmod +x "$STUB/find"

# mk_round <name> — a plans dir carrying a two-concern ledger and both declared
# producers' deltas for round 2, staged by the real CLI so the header the
# readers parse is the one the writer really emits.
mk_round() {
    local p="$TMPDIR_BASE/$1" prod
    mkdir -p "$p"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$FMT" "$SID"
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|dc601|review-code-codex|review-code-codex|-|first concern\n'
        printf 'C2|LOW|open|1|1|bin/y#fn:security|dc602|security-scanner|security-scanner|-|second concern\n'
    } > "$p/$SID-$FMT-concern-ledger.txt"
    for prod in review-code-codex security-scanner; do
        bash "$CLI" stage --plans-dir "$p" --session-id "$SID" --format "$FMT" \
            --round 2 --producer "$prod" --from-report "$REPORT" \
            --exec PERFORMED >/dev/null 2>&1
    done
    printf '%s' "$p"
}

led_of() { printf '%s/%s-%s-concern-ledger.txt' "$1" "$SID" "$FMT"; }

# state <plans> — what the ledger says, as one line: how many concerns it holds,
# how many the round resolved, and how many it wrongly wrote off as stale.
state() {
    local f
    f="$(led_of "$1")"
    printf 'entries=%s resolved=%s stale=%s' \
        "$(grep -c '^C[0-9]' "$f" 2>/dev/null | tr -d ' ')" \
        "$(grep -c '^C[0-9][^|]*|[^|]*|resolved|' "$f" 2>/dev/null | tr -d ' ')" \
        "$(grep -c '|stale|' "$f" 2>/dev/null | tr -d ' ')"
}

echo "--- discovery 1: the control, so the injection is not mistaken for a no-op ---"

# 1. What a round of this shape does when discovery works. Every expectation in
#    cases 2-4 is a departure from this line, so without it "the ledger changed"
#    would carry no information about which direction it changed in.
{
    P1="$(mk_round ctl)"
    assert_eq_nz "1: both producers staged their round-2 delta (precondition)" \
        "2" "$(find "$P1" -name "$SID-$FMT-round-2-delta-*.txt" | wc -l | tr -d ' ')"

    RC1=0
    T1="$(bash "$CLI" reduce --plans-dir "$P1" --session-id "$SID" \
        --format "$FMT" --round 2 2>/dev/null)" || RC1=$?
    assert_eq "1: the reduction succeeds and reports the round it read" \
        "rc=0 tally=open_high=1 open_medium=0 open_low=0 reopened=0 resolved=2" \
        "rc=$RC1 tally=$(printf '%s' "$T1" | tr -d '\r\n')"
    assert_eq "1: the two prior concerns are resolved and the new one recorded" \
        "entries=3 resolved=2 stale=0" "$(state "$P1")"

    bash "$CLI" finalize --plans-dir "$P1" --session-id "$SID" --format "$FMT" \
        --round 2 --cap 2 --mode terminal --reason 'control' >/dev/null 2>&1
    assert_eq_nz "1: and the artifact names the producers that contributed" \
        "2" "$(grep -c -E '"(review-code-codex|security-scanner)"' \
            "$P1/$SID-$FMT-unresolved-concerns.json" 2>/dev/null | tr -d ' ')"
}

echo ""
echo "--- discovery 2: the reducer, with the mechanism failing under it ---"

# 2. The same round with `find` failing. The reducer used to see an empty list,
#    conclude that no producer reported this round, mark every open concern
#    stale and drop the round's new finding — reporting rc 0 and a tally while
#    it did. Silent loss of a whole round is the worst of the failure modes
#    this subsystem has, so the contract is a refusal.
{
    P2="$(mk_round fail-reduce)"
    BEFORE2="$(cat "$(led_of "$P2")")"
    RC2=0
    ERR2="$(PATH="$STUB:$PATH" bash "$CLI" reduce --plans-dir "$P2" \
        --session-id "$SID" --format "$FMT" --round 2 2>&1 >/dev/null)" || RC2=$?

    # Both deltas are on disk and the round's finding still did not land: the
    # stub broke discovery rather than the fixture failing to stage.
    assert_eq "2: the injection really did break discovery (precondition)" \
        "deltas=2 recorded=no" \
        "deltas=$(find "$P2" -name "$SID-$FMT-round-2-delta-*.txt" | wc -l | tr -d ' ') recorded=$(grep -q 'the round-two finding' "$(led_of "$P2")" && printf yes || printf no)"

    assert_eq "2: a reduction that could not read the round refuses rather than succeeding" \
        "refused" "$([ "$RC2" -ne 0 ] && printf refused || printf accepted)"
    assert_eq "2: and leaves the ledger exactly as it found it" \
        "unchanged" \
        "$([ "$BEFORE2" = "$(cat "$(led_of "$P2")")" ] && printf unchanged || printf rewritten)"
    assert_eq "2: rather than writing off every open concern as stale" \
        "stale=0" "stale=$(state "$P2" | sed 's/.*stale=//')"
    assert_contains "2: and says why, so the round is not lost in silence" \
        "concern-ledger" "$ERR2"
}

echo ""
echo "--- discovery 3: check-staged tells a broken mechanism from an empty dir ---"

# 3. check-staged uses the same helper for a format with no declared producer
#    set. "Nothing staged yet" is the loop's normal, retryable state; a broken
#    discovery is not, and the caller has to be able to tell them apart before
#    it decides whether to wait or to stop.
{
    UFMT="custom-format-x"
    P3="$TMPDIR_BASE/fail-staged"
    mkdir -p "$P3"
    bash "$CLI" stage --plans-dir "$P3" --session-id "$SID" --format "$UFMT" \
        --round 2 --producer someprod --from-report "$REPORT" \
        --exec PERFORMED >/dev/null 2>&1
    P3E="$TMPDIR_BASE/empty-staged"
    mkdir -p "$P3E"

    cs() {
        local rc=0 out
        out="$(PATH="$1" bash "$CLI" check-staged --plans-dir "$2" \
            --session-id "$SID" --format "$UFMT" --round 2 2>&1)" || rc=$?
        printf 'rc=%s out=%s' "$rc" "$out"
    }

    OK3="$(cs "$PATH" "$P3")"
    BEFORE3="$(find "$P3" -maxdepth 1 -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
    BROKEN3="$(cs "$STUB:$PATH" "$P3")"
    NOTHING3="$(cs "$PATH" "$P3E")"

    assert_eq "3: with discovery working, the staged round reads as complete" \
        "rc=0 out=" "$OK3"
    assert_eq "3: and a genuinely empty round reads as nothing staged" \
        "rc=1 out=(no format):missing" "$NOTHING3"

    # The same three attributes cases 2 and 4 are asserted on (CPR-ORTH): the
    # verdict, what the run left on disk, and whether the failure was said out
    # loud. check-staged writes nothing, so its middle attribute holds today.
    assert_eq_nz "3: a check-staged that could not read the round writes nothing either way" \
        "$BEFORE3" "$(find "$P3" -maxdepth 1 -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
    assert_eq "3: a broken mechanism does not get reported as an empty round" \
        "distinct" \
        "$([ "$BROKEN3" = "$NOTHING3" ] && printf identical || printf distinct)"
    assert_eq "3: the exit status separates 'cannot tell' from 'nothing staged yet'" \
        "distinct-rc" \
        "$([ "${BROKEN3%% *}" = "${NOTHING3%% *}" ] && printf same-rc || printf distinct-rc)"
    assert_contains "3: and the reason names the mechanism, not the round" \
        "discovery" "$BROKEN3"
}

echo ""
echo "--- discovery 4: finalize withholds the artifact it could not name producers in ---"

# 4. The producer list is finalize's record of who actually reviewed the round,
#    and a skill reads it back to decide whether the verdict is trustworthy. An
#    empty list is a factual claim that nobody reviewed, so publishing one on a
#    round two producers did stage is worse than publishing nothing.
{
    P4="$(mk_round fail-finalize)"
    RC4=0
    OUT4="$(PATH="$STUB:$PATH" bash "$CLI" finalize --plans-dir "$P4" \
        --session-id "$SID" --format "$FMT" --round 2 --cap 2 \
        --mode terminal --reason 'mechanism check' 2>&1)" || RC4=$?
    J4="$P4/$SID-$FMT-unresolved-concerns.json"

    # Both deltas are on disk and nothing anywhere in the plans dir records a
    # producer: the stub broke finalize's own producer scan rather than the
    # fixture failing to stage. Only a JSON artifact quotes a producer name, so
    # the second half counts artifacts that made a claim about who reviewed.
    assert_eq "4: the injection reached finalize's own producer scan (precondition)" \
        "deltas=2 naming-producers=0" \
        "deltas=$(find "$P4" -name "$SID-$FMT-round-2-delta-*.txt" | wc -l | tr -d ' ') naming-producers=$(grep -rl -E '"(review-code-codex|security-scanner)"' "$P4" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "4: finalize does not publish an artifact whose producer list it could not build" \
        "withheld" "$([ -s "$J4" ] && printf published || printf withheld)"
    assert_eq "4: and reports the failure rather than a path to that artifact" \
        "reported" "$([ "$RC4" -ne 0 ] && printf reported || printf silent)"
    assert_contains "4: naming the finalize failure the loop already knows how to read" \
        "FINALIZE-FAILED" "$OUT4"
}

echo ""
echo "--- discovery 5: one helper owns all three, so one fix covers them ---"

# 5. Cases 2-4 are three symptoms of one swallowed status (CPR-SSOT). Pinned at
#    the helper so the fix is made once, where the mechanism is, rather than
#    three times at the callers.
{
    CORE="$AGENTS_ROOT/bin/lib/concern-ledger/core.sh"
    BODY="$(awk '/^_cl_list_pattern_files\(\)/, /^}/' "$CORE")"
    # Counted as "exactly one find invocation on the directory half", not as a
    # literal spelling: '--' was removed because BSD/macOS find reads it as a
    # path operand rather than an option terminator, so pinning it here would
    # hold the fix to a spelling that breaks discovery off GNU. Comment lines
    # are excluded so the body's prose about find is not counted as a call.
    assert_eq_nz "5: the helper is still the single discovery mechanism" \
        "1" "$(printf '%s\n' "$BODY" | grep -c -E '^[^#]*(^|[^[:alnum:]_-])find[[:space:]]+"\$dir"' | tr -d ' ')"
    assert_eq "5: and it does not discard find's status along with its stderr" \
        "checked" \
        "$(printf '%s' "$BODY" | grep -qE 'PIPESTATUS|rc=|\$\?' && printf checked || printf discarded)"
}

# shellcheck source=./fix-2025-discovery-failure-failclosed/real-and-scope.sh
. "$AGENTS_ROOT/tests/fix-2025-discovery-failure-failclosed/real-and-scope.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
