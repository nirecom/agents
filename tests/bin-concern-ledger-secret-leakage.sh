#!/usr/bin/env bash
# tests/bin-concern-ledger-secret-leakage.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/render.sh
# Tags: concern-ledger, security, secret-leakage, redaction, table-driven, xfail, scope:common, pwsh-not-required
#
# A code reviewer reads the diff, and a diff is where credentials get committed
# by accident. So the single most likely secret-bearing string in the whole
# system is the concern text itself: "hardcoded API key in config.sh: <key>".
# The ledger then does the one thing that makes a leak permanent — it persists
# that text to disk, carries it forward across rounds, and re-emits it into an
# artifact and into the next round's prompt.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"

PASS=0
FAIL=0

# Every case here is a known gap: no redaction exists anywhere on this path.
# See tests/lib/xfail.sh — the helpers assert the correct behaviour and count
# an XPASS as a failure, so closing the gap forces these pins to be removed.
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

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md).
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

if [ ! -f "$CLI" ]; then
    echo "SKIP-BLOCKED: bin/concern-ledger not implemented yet"
    echo "FAIL: implementation missing (every case below fails for this reason)"
    exit 1
fi

# ---------------------------------------------------------------------------
# The bait. Assembled at runtime from a prefix and a filler so that no line of
# this file is itself a secret-shaped literal: bin/scan-outbound.sh scans this
# repo's own commits, and a test that trips the outbound scanner is a test that
# can never land. The runtime value still matches the provider patterns, which
# is what a redactor would have to recognise.
# ---------------------------------------------------------------------------
FILL='0123456789abcdefghijklmnopqrstuvwxyz'
mk_token() { printf '%s%s' "$1" "${FILL:0:$2}"; }

SEC_ANTHROPIC="$(mk_token 'sk-ant-api03-' 28)"
SEC_OPENAI="$(mk_token 'sk-proj-' 32)"
SEC_GITHUB="$(mk_token 'ghp_' 36)"
SEC_AWS="$(mk_token 'AKIA' 16 | tr 'a-z' 'A-Z')"
SEC_BEARER="Bearer $(mk_token 'eyJ' 40)"

# A redactor's job is to remove the secret and leave the concern legible, so
# every case checks both halves: the token is gone, the sentence survives.
KEEP='hardcoded credential in bin/deploy.sh'

# ---------------------------------------------------------------------------
# A full round, driven through the real CLI: stage -> reduce -> finalize, with
# a HIGH concern whose text carries the token. Sets the five surface variables.
# ---------------------------------------------------------------------------
SEQ=0
PLANS=""; SID=""; FMT='detail-plan'
SL_STDOUT=""; SL_STDERR=""

run_round() {
    local token="$1"
    SEQ=$((SEQ + 1))
    SID="sl$SEQ"
    PLANS="$TMPDIR_BASE/plans-$SEQ"
    mkdir -p "$PLANS"

    local report="$PLANS/report.txt"
    {
        printf '# Report\n\n## Review: PERFORMED\n\n## Concern Delta\n'
        printf -- '- [HIGH] - | bin/deploy.sh#main | security | %s: %s\n' "$KEEP" "$token"
        printf '\n'
    } > "$report"

    local out="$TMPDIR_BASE/out-$SEQ.txt" err="$TMPDIR_BASE/err-$SEQ.txt"
    : > "$out"; : > "$err"

    bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --round 1 --producer review-code-codex --from-report "$report" \
        >>"$out" 2>>"$err"
    bash "$CLI" reduce --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --round 1 >>"$out" 2>>"$err"
    bash "$CLI" finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FMT" \
        --mode LAND --reason 'cap reached' --round 1 --cap 1 >>"$out" 2>>"$err"

    SL_STDOUT="$(cat "$out")"
    SL_STDERR="$(cat "$err")"
}

# The five persisted-or-emitted surfaces, each read back from where it lives.
sl_delta()  { cat "$PLANS/$SID-$FMT-round-1-delta-review-code-codex.txt" 2>/dev/null; }
sl_ledger() { cat "$PLANS/$SID-$FMT-concern-ledger.txt" 2>/dev/null; }
sl_json()   { cat "$PLANS/$SID-$FMT-unresolved-concerns.json" 2>/dev/null; }
sl_prior()  {
    bash "$CLI" render-prior --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FMT" 2>/dev/null
}

# has <needle> <haystack> — 'present' / 'absent', so a row reads as a verdict.
has() { printf '%s' "$2" | grep -Fq -- "$1" && printf 'present' || printf 'absent'; }

# ---------------------------------------------------------------------------
# 1. The persisted surfaces. Ordered by how long the leak survives: the delta
#    is one round, the ledger is the whole session, the artifact outlives it.
# ---------------------------------------------------------------------------
echo ""
echo "--- secrets 1: a credential in the concern text must not be persisted ---"

run_round "$SEC_ANTHROPIC"

# The round has to have worked at all, or every 'absent' below is vacuous.
assert_eq "1: the round reached disk, so the surfaces below are real" \
    "delta=present ledger=present" \
    "delta=$(has "$KEEP" "$(sl_delta)") ledger=$(has "$KEEP" "$(sl_ledger)")"

xfail_not_contains "1: the staging file the producer wrote holds no credential" \
    "$SEC_ANTHROPIC" "$(sl_delta)"
xfail_not_contains "1: the session-long ledger holds no credential" \
    "$SEC_ANTHROPIC" "$(sl_ledger)"
xfail_not_contains "1: the artifact that outlives the session holds no credential" \
    "$SEC_ANTHROPIC" "$(sl_json)"

# Redaction is not deletion: the reviewer's point has to survive it.
assert_eq "1: and the concern itself stays legible on every surface" \
    "delta=present ledger=present json=present" \
    "delta=$(has "$KEEP" "$(sl_delta)") ledger=$(has "$KEEP" "$(sl_ledger)") json=$(has "$KEEP" "$(sl_json)")"

# ---------------------------------------------------------------------------
# 2. The emitted surfaces. A terminal scrollback and a CI log are copied and
#    pasted far more casually than a file is, and the prior-concerns render is
#    fed straight back into a third-party model's prompt.
# ---------------------------------------------------------------------------
echo ""
echo "--- secrets 2: nor emitted to a log, a terminal, or the next prompt ---"

# stdout and stderr are already clean, and that is worth pinning rather than
# assuming: the CLI reports counts and paths, never concern bodies. A change
# that starts echoing a staged concern for debugging would break this pair.
assert_eq "2: the run did emit progress output, so the next check is not vacuous" \
    "spoke" "$([ -n "$SL_STDOUT" ] && printf spoke || printf silent)"
assert_eq "2: the CLI's own stdout carries no credential" \
    "absent" "$(has "$SEC_ANTHROPIC" "$SL_STDOUT")"
assert_eq "2: nor do its diagnostics on stderr" \
    "absent" "$(has "$SEC_ANTHROPIC" "$SL_STDERR")"
xfail_not_contains "2: nor the prior-concerns block handed to the next reviewer" \
    "$SEC_ANTHROPIC" "$(sl_prior)"
assert_eq "2: which still carries the concern the next round must answer" \
    "present" "$(has "$KEEP" "$(sl_prior)")"

# ---------------------------------------------------------------------------
# 3. Every provider family, over every surface. One provider being handled is
#    not redaction — a redactor that knows only one prefix leaks the other four
#    (CPR-ORTH), and the table is what makes that visible.
# ---------------------------------------------------------------------------
echo ""
echo "--- secrets 3: every credential family, over every surface ---"

while IFS='~' read -r LABEL VAR; do
    LABEL="${LABEL#"${LABEL%%[![:space:]]*}"}"; LABEL="${LABEL%"${LABEL##*[![:space:]]}"}"
    VAR="${VAR#"${VAR%%[![:space:]]*}"}"; VAR="${VAR%"${VAR##*[![:space:]]}"}"
    [ -n "$LABEL" ] || continue
    TOKEN="${!VAR}"
    run_round "$TOKEN"

    SURFACES="delta=$(has "$TOKEN" "$(sl_delta)") ledger=$(has "$TOKEN" "$(sl_ledger)")"
    SURFACES="$SURFACES json=$(has "$TOKEN" "$(sl_json)") prior=$(has "$TOKEN" "$(sl_prior)")"
    SURFACES="$SURFACES stdout=$(has "$TOKEN" "$SL_STDOUT") stderr=$(has "$TOKEN" "$SL_STDERR")"

    xfail_eq "3: a $LABEL credential reaches none of the six surfaces" \
        "delta=absent ledger=absent json=absent prior=absent stdout=absent stderr=absent" \
        "$SURFACES"
done <<'FAMILIES'
anthropic api key   ~ SEC_ANTHROPIC
openai project key  ~ SEC_OPENAI
github token        ~ SEC_GITHUB
aws access key id   ~ SEC_AWS
bearer jwt          ~ SEC_BEARER
FAMILIES

# ---------------------------------------------------------------------------
# 4. The repo already owns a secret detector. Whatever redaction is eventually
#    added has to agree with it, or the two disagree about what a secret is and
#    the ledger becomes the hole in the scanner (CPR-SSOT). This case asserts
#    the agreement in the only direction that is testable now: the scanner does
#    flag what the ledger persisted, so the ledger is genuinely leaking.
# ---------------------------------------------------------------------------
echo ""
echo "--- secrets 4: the leak is one this repo's own scanner would catch ---"

SCANNER="$AGENTS_ROOT/bin/scan-outbound.sh"
if [ ! -f "$SCANNER" ]; then
    echo "FAIL: 4: bin/scan-outbound.sh is missing — the agreement cannot be checked"
    FAIL=$((FAIL + 1))
else
    run_round "$SEC_GITHUB"
    LEAKED="$TMPDIR_BASE/leaked-ledger.txt"
    sl_ledger > "$LEAKED"
    SCAN_RC=0
    SCAN_OUT="$(bash "$SCANNER" "$LEAKED" 2>&1)" || SCAN_RC=$?

    assert_eq "4: the scanner rejects the ledger the CLI just wrote" \
        "flagged" "$([ "$SCAN_RC" -ne 0 ] && printf flagged || printf clean)"
    assert_eq "4: naming the credential family it found there" \
        "present" "$(has 'github-token' "$SCAN_OUT")"
fi

xfail_summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
