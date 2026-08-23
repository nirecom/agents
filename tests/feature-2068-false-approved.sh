#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/concern-ledger, bin/review-loop-verdict
# Tags: codex-review-loop, concern-ledger, fail-closed, false-approved, table-driven, TL2, scope:issue-specific
#
# #2068 (P2.5): APPROVED was reachable without anyone approving anything. The
# verdict is computed from a tally of the ledger, so a reduce that failed — or a
# ledger left with only its header — counted zero open concerns and read as a
# clean plan. The tally is only meaningful when the ledger it came from is, so
# both states must stop the loop instead of scoring it.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
# shellcheck source=./lib/codex-loop-fixture.sh
. "$AGENTS_ROOT/tests/lib/codex-loop-fixture.sh"

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

ROOT="$TMPDIR_BASE/agents"
clf_make_root "$ROOT" "$AGENTS_ROOT"
clf_stub_reviewer "$ROOT"

# The ledger CLI is shimmed rather than replaced: every subcommand but reduce
# runs for real, so each case differs from a healthy round in exactly one way.
cat > "$ROOT/bin/concern-ledger" <<SHIM
#!/usr/bin/env bash
REAL="$AGENTS_ROOT/bin/concern-ledger"
SUB="\${1:-}"
if [ "\$SUB" != "reduce" ] || [ "\${FA_MODE:-healthy}" = "healthy" ]; then
  exec bash "\$REAL" "\$@"
fi
if [ "\$FA_MODE" = "reduce-fail" ]; then
  echo "concern-ledger: reduce could not be completed (injected failure)" >&2
  exit 1
fi
OUT="\$(bash "\$REAL" "\$@")"; RC=\$?
LEDGER=""
while [ \$# -gt 0 ]; do
  case "\$1" in --ledger) LEDGER="\${2:-}"; shift 2 ;; *) shift ;; esac
done
if [ -n "\$LEDGER" ] && [ -f "\$LEDGER" ]; then
  grep -v -E '^C[0-9]+\|' "\$LEDGER" > "\$LEDGER.hdr" 2>/dev/null || true
  mv -f "\$LEDGER.hdr" "\$LEDGER"
fi
printf '%s\n' "\$OUT"
exit \$RC
SHIM
chmod +x "$ROOT/bin/concern-ledger"

# fa_run <mode> <plans> <sid> — one round 1 with the named ledger damage.
fa_run() {
    local errf="$2/fa-err.txt"
    FA_RC=0
    FA_OUT="$(
        export AGENTS_CONFIG_DIR="$ROOT" FA_MODE="$1"
        bash "$ROOT/bin/run-codex-review-loop" --format detail-plan --session-id "$3" \
            --plans-dir "$2" --draft-file "$2/draft.md" \
            --accepted-tradeoffs "$2/tradeoffs.md" \
            --cap 2 --max-extensions 1 --extensions-used 0 --round 1 2>"$errf"
    )" || FA_RC=$?
    FA_ERR="$(cat "$errf" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 1. A ledger that cannot be trusted must not produce a verdict. Each row breaks
#    the ledger in one way and asks the only question that matters: was the
#    round scored anyway? The healthy row is in the same table on purpose — a
#    fixture where everything fails would prove nothing about the failures.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-fa-1: a broken ledger stops the round instead of approving it ---"

while IFS='|' read -r FA_MODE_ROW FA_RC_WANT FA_NEEDLE FA_WHY; do
    case "$FA_MODE_ROW" in ''|\#*) continue ;; esac

    PLANS="$TMPDIR_BASE/plans-$FA_MODE_ROW"
    SID="fa-$FA_MODE_ROW"
    clf_plans "$PLANS"
    COUNTER="$(clf_round_path "$PLANS" "$SID" detail-plan)"
    BEFORE="$(clf_file_state "$COUNTER")"

    fa_run "$FA_MODE_ROW" "$PLANS" "$SID"

    assert_eq "1 ($FA_MODE_ROW): $FA_WHY" "$FA_RC_WANT" "$FA_RC"
    if [ -n "$FA_NEEDLE" ]; then
        # The two failures are told apart by what they say: a caller that only
        # sees "exit 4" cannot tell a damaged ledger from a bad argument.
        assert_contains "1 ($FA_MODE_ROW): and says which part of the ledger failed" \
            "$FA_NEEDLE" "$FA_ERR"
        assert_ne "1 ($FA_MODE_ROW): the round is specifically not reported as APPROVED" \
            "0" "$FA_RC"
        assert_not_contains "1 ($FA_MODE_ROW): and no APPROVED verdict reaches stdout either" \
            "APPROVED" "$FA_OUT"
        assert_eq "1 ($FA_MODE_ROW): the round is not consumed — the counter is as it was" \
            "$BEFORE" "$(clf_file_state "$COUNTER")"
        assert_eq "1 ($FA_MODE_ROW): and no unresolved-concerns artifact claims the round ended" \
            "missing" "$(clf_file_state "$(clf_artifact_path "$PLANS" "$SID" detail-plan)")"
    fi
done <<'MODES'
reduce-fail|4|could not be folded into the ledger|a reduce that failed cannot yield a verdict
header-only|4|no valid concern entries|a ledger holding no concern entries is damaged, not clean
healthy|1||the same fixture with an intact ledger still reviews normally
MODES

# ---------------------------------------------------------------------------
# 2. The healthy control, examined. The point of the rows above is that the
#    APPROVED they must not return was genuinely reachable: with the ledger
#    intact, the very same round produces a real tally and a real concern.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-fa-2: the control round really does exercise the tally ---"

HEALTHY_LEDGER="$(clf_ledger_path "$TMPDIR_BASE/plans-healthy" "fa-healthy" detail-plan)"
assert_eq "2: the intact round left a ledger behind" "present" "$(clf_file_state "$HEALTHY_LEDGER")"
assert_contains "2: with a real concern entry in it, which is what the tally counts" \
    "C1|" "$(cat "$HEALTHY_LEDGER" 2>/dev/null)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
