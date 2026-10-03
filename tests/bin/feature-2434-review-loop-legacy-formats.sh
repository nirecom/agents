#!/usr/bin/env bash
# tests/bin/feature-2434-review-loop-legacy-formats.sh
# Tests: skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/run-codex-review-loop, hooks/lib/plans-artifact-registry.js
# Tags: feature-2434, control-dir, codex-review-loop, legacy-migration, TL2, scope:issue-specific, pwsh-not-required
#
# #2434 Step 2-1 / Step 5-9: a session that started before the upgrade keeps its
# review state in every one of the five review-loop formats. A legacy PLANS_DIR
# round counter and concern ledger are migrated into <sid>.control/ and continued:
# the next run is round 2 (budget resumed, not restarted) and the prior ledger
# entries survive. The detail-plan-only multi-run variant stays in
# tests/skills/fix-776-748-exit4-cleanup-and-recovery.sh (legacy-round-number-continues).
set -uo pipefail

# TL2 — the real wrappers and loop, reviewers stubbed (shared fixture). One wrapper
# run per format keeps the suite at five runs inside the 120 s budget.
# TL3 gap: the real codex CLI wording, and a ledger written by a pre-#2434 build
# (the seeded row mirrors schema v2 as documented in bin/lib/concern-ledger.sh).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$AGENTS_DIR/tests/bin/feature-2434-review-loop/fixture.sh"

for f in bin/workflow-control-dir hooks/workflow-state/state-io/control-dir.js hooks/lib/plans-artifact-registry.js; do
    [ -f "$AGENTS_DIR/$f" ] || fail "implementation missing: $f"
done

case_begin "format-table-drift-guard" "bin/run-codex-review-loop"
# The FORMATS table (fixture SSOT) must cover every stage wrapper and agree with the
# loop's own per-format parameters and the registry's format tokens, so a sixth
# review-loop format cannot ship without legacy-continuation coverage here.
WANT_SKILLS=""
for w in "$AGENTS_DIR"/skills/*/scripts/run-codex-review-loop.sh; do
    [ -f "$w" ] || continue
    s="${w%/scripts/run-codex-review-loop.sh}"
    WANT_SKILLS="$WANT_SKILLS ${s##*/}"
done
WANT_SKILLS="$(printf '%s\n' $WANT_SKILLS | sort | tr '\n' ' ')"
GOT_SKILLS="$(printf '%s\n' "$FORMATS" | cut -d'|' -f2 | sort | tr '\n' ' ')"
assert_eq "FORMATS covers exactly the stage wrappers on disk" "$WANT_SKILLS" "$GOT_SKILLS"
# shellcheck source=bin/lib/codex-review-loop/format-params.sh
. "$AGENTS_DIR/bin/lib/codex-review-loop/format-params.sh"
while IFS='|' read -r NAME SKILL FMT LFMT PROD; do
    FP_REVIEWER=""; FP_LEDGER_FORMAT=""
    if fp_resolve "$FMT"; then
        pass "$NAME: the loop accepts --format $FMT"
    else
        fail "$NAME: the loop does not know --format $FMT"
    fi
    assert_eq "$NAME: ledger format matches the loop" "$LFMT" "$FP_LEDGER_FORMAT"
    assert_eq "$NAME: producer matches the loop" "$PROD" "$FP_REVIEWER"
    assert_contains "$NAME: the wrapper passes --format $FMT" "--format $FMT" \
        "$(cat "$AGENTS_DIR/skills/$SKILL/scripts/run-codex-review-loop.sh")"
done <<EOF
$FORMATS
EOF
REG="$AGENTS_DIR/hooks/lib/plans-artifact-registry.js"
if [ -f "$REG" ]; then
    GOT_TOKENS="$(node -e 'const r=require(process.argv[1]);console.log([...(r.FORMAT_TOKENS||[])].sort().join(","))' "$(np "$REG")" 2>/dev/null)"
    WANT_TOKENS="$(printf '%s\n' "$FORMATS" | cut -d'|' -f3,4 | tr '|' '\n' | sort -u | tr '\n' ',')"
    assert_eq "registry FORMAT_TOKENS equals the loop and ledger formats of FORMATS" \
        "${WANT_TOKENS%,}" "$GOT_TOKENS"
else
    fail "implementation missing: hooks/lib/plans-artifact-registry.js (FORMAT_TOKENS drift guard)"
fi
case_end

case_begin "legacy-round-and-ledger-continue-all-formats" "bin/run-codex-review-loop"
# One wrapper run per format. Seed only the pre-#2434 PLANS names, shaped like a
# real round-1 state: round counter 1 and a v2 ledger holding the open HIGH C1 that
# the stub reviewer's round-2 "C1: still open" line refers to, plus a MEDIUM C7 it
# never mentions. Continued state keeps C1 open (rc 5); a lost ledger turns C1 into
# an unknown MEDIUM and the loop approves (rc 0), so the rc alone separates the two.
LEGACY_TEXT="legacy seeded concern survives the control-dir migration"
C1_TEXT="a high severity concern that must never be absorbed as approved"
while IFS='|' read -r NAME SKILL FMT LFMT PROD; do
    SID="lg-$NAME"
    seed_sid "$SID"
    printf '1\n' > "$P/$SID-$FMT-round-number.txt"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$LFMT" "$SID"
        printf 'C1|HIGH|open|1|1|legacy-slot-c1|c1d15c|%s|%s|-|%s\n' "$PROD" "$PROD" "$C1_TEXT"
        printf 'C7|MEDIUM|open|1|1|legacy-slot-c7|c7d15c|%s|%s|-|%s\n' "$PROD" "$PROD" "$LEGACY_TEXT"
    } > "$P/$SID-$LFMT-concern-ledger.txt"
    export CLF_ROUND_LOG="$TMP/lg-rounds-$NAME.txt"
    : > "$CLF_ROUND_LOG"
    wrap "$SKILL" "$SID"
    C="$(ctl "$SID")"
    assert_eq "$NAME: resumed round 2 with an open HIGH auto-extends (rc 5, not a restart or a ledger refusal)" \
        "5" "$W_RC"
    assert_eq "$NAME: control-dir round counter continued to 2" "2" "$(clf_read "$C/$FMT-round-number.txt")"
    assert_eq "$NAME: the resumed run produced the round-2 delta" "present" \
        "$(state "$C/$LFMT-round-2-delta-$PROD.txt")"
    assert_eq "$NAME: no round-1 delta (the round was not restarted)" "absent" \
        "$(state "$C/$LFMT-round-1-delta-$PROD.txt")"
    if [ "$PROD" = "review-plan-codex" ]; then
        assert_eq "$NAME: the reviewer was handed round 2" "2" "$(tr -d '\r\n' < "$CLF_ROUND_LOG")"
    fi
    LEDGER="$C/$LFMT-concern-ledger.txt"
    assert_eq "$NAME: ledger migrated into the control dir" "present" "$(state "$LEDGER")"
    assert_contains "$NAME: migrated ledger keeps its v2 header for this format and session" \
        "#concern-ledger-v2|$LFMT|$SID|" "$(head -n 1 "$LEDGER" 2>/dev/null)"
    assert_contains "$NAME: the prior concern C7 survives with its text" \
        "$LEGACY_TEXT" "$(grep '^C7|' "$LEDGER" 2>/dev/null)"
    if [ "$PROD" = "review-plan-codex" ]; then
        assert_contains "$NAME: the carried HIGH C1 is still open under its original id" \
            "C1|HIGH|open|1|" "$(grep '^C1|' "$LEDGER" 2>/dev/null)"
    fi
    assert_eq "$NAME: legacy round counter left PLANS_DIR" "absent" "$(state "$P/$SID-$FMT-round-number.txt")"
    assert_eq "$NAME: legacy ledger left PLANS_DIR" "absent" "$(state "$P/$SID-$LFMT-concern-ledger.txt")"
    assert_eq "$NAME: PLANS_DIR keeps artifacts only" "" "$(plans_leftovers "$SID")"
    unset CLF_ROUND_LOG
done <<EOF
$FORMATS
EOF
case_end

finish
