#!/usr/bin/env bash
# tests/feature-2344-rejected-state.sh
# Tests: bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger/render.sh, bin/concern-ledger
# Tags: concern-ledger, rejected-state, issue-2344, TL1, scope:issue-specific, pwsh-not-required, dup-group-keep:size-hard-limit
# dup-group-keep:size-hard-limit: 435+237=672>500 HARD; excluded=- tool limit; WARNINGS_ACCEPTED.
# Test-first suite for change 3/5 of issue #2344: the 'rejected' STATE value.
# C1/C4/C5 are RED pre-implementation. C2/C3/C6 may be green pre-impl (the
# "unknown subcommand" exit-2 path produces the same observable output as the
# correct implementation for those contracts — acknowledged limitation).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$AGENTS_ROOT/bin/concern-ledger"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() {
    if [ -n "${2:-}" ]; then echo "FAIL: $1 — $2"; else echo "FAIL: $1"; fi
    FAIL=$((FAIL + 1))
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# assert_eq_nz: empty expected value is itself a FAIL (anti-false-green).
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — expected value could not be computed (empty — library not loaded?)"
        FAIL=$((FAIL + 1)); return
    fi
    assert_eq "$name" "$want" "$got"
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else echo "FAIL: $name — output does not contain $(printf '%q' "$needle"). Got: $(printf '%q' "$hay")"; FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle"). Got: $(printf '%q' "$hay")"; FAIL=$((FAIL + 1))
    else pass "$name"
    fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Fixture isolation (rules/test/fixture-isolation.md): dual-pinned plans dir,
# no inherited session id, neutral CWD.
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID  2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE    2>/dev/null || true
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

# ---------------------------------------------------------------------------
# Library driver — every library call runs in its own subshell (pattern #2111).
# ---------------------------------------------------------------------------
CLG_LIB_LOADED=0
cl() {
    [[ "$CLG_LIB_LOADED" -eq 1 ]] || return 127
    ( set +u; "$@" )
}
discrim_of() {
    [[ "$CLG_LIB_LOADED" -eq 1 ]] || { printf ''; return; }
    set +u; cl_discrim "$1"; set -u
}
slot_of() {
    [[ "$CLG_LIB_LOADED" -eq 1 ]] || { printf 'b00000000'; return; }
    set +u; cl_slot_body "$1"; set -u
}
run_cli() { bash "$CLI" "$@"; }

# Implementation presence — missing file → FAIL, never absorbed into SKIP/PASS
for _f in "$LIB" "$CLI"; do
    if [[ ! -f "$_f" ]]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"}" \
            "every case below fails for this reason"
    fi
done

if [[ -f "$LIB" ]]; then
    set +u
    if source "$LIB" >/dev/null 2>&1; then CLG_LIB_LOADED=1; fi
    set -u
fi
if [[ "$CLG_LIB_LOADED" -eq 1 ]]; then
    set +u; cl_sha256 "cl-identity-probe" >/dev/null 2>&1 || true; set -u
fi

# ---------------------------------------------------------------------------
# Ledger-v2 fixture builders (schema: 11 fields, TEXT last).
# SLOT/DISCRIM computed by real helpers — never hardcoded (anti-false-green).
# ---------------------------------------------------------------------------
mk_ledger() { printf '#concern-ledger-v2|%s|%s|cycle=%s\n' "$2" "$3" "$4" > "$1"; }

# add_entry <file> <id> <sev> <state> <first> <last> <slot> <discrim> <origin> <producers> <flags> <text>
add_entry() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" >> "$1"
}

F_SEV=2; F_STATE=3; F_FIRST=4; F_LAST=5; F_SLOT=6; F_DISCRIM=7
F_ORIGIN=8; F_PRODUCERS=9; F_FLAGS=10

entry_field() { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f"$3"; }
entry_text()  { grep -m1 -- "^$2|" "$1" 2>/dev/null | cut -d'|' -f11-; }

anchored() { printf '[%s] %s | %s#%s | %s | %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }

mk_delta_report() {
    local f="$1" l; shift
    { printf '## Codex Review: PERFORMED\n\n## Concern Delta\n'
      for l in "$@"; do printf '%s\n' "$l"; done
      printf '\n'; } > "$f"
}

NONE_REPORT="$TMPDIR_BASE/none-delta.txt"
mk_delta_report "$NONE_REPORT" "(none)"

# reduce_round <in-ledger> <out-ledger> <round> <format> <spec>...
# spec = "<producer>@<exec-label>@<raw-delta-file>"
# Sets LAST_TALLY / LAST_REDUCE_RC / LAST_REDUCE_ERR / LAST_RUN_DIR.
reduce_round() {
    local inl="$1" outl="$2" round="$3" fmt="$4"; shift 4
    local run spec prod exec_lbl raw rest norm plabel
    run=$(mktemp -d "$TMPDIR_BASE/rr-XXXXXX")
    mkdir -p "$run/staging" "$run/norm"
    : > "$run/err.txt"
    for spec in "$@"; do
        prod="${spec%%@*}"; rest="${spec#*@}"
        exec_lbl="${rest%%@*}"; raw="${rest#*@}"
        norm="$run/norm/$prod.txt"; : > "$norm"
        plabel=$(cl cl_parse_anchored "$raw" "$prod" "$norm" 2>>"$run/err.txt" | head -n1)
        plabel="$(trim "${plabel:-}")"
        [[ -n "$plabel" ]] || plabel="ABSENT"
        cl cl_stage "$run/staging" "$fmt" "$round" "$prod" \
            "$exec_lbl" "$plabel" "$norm" >/dev/null 2>>"$run/err.txt"
    done
    LAST_TALLY=$(cl cl_reduce "$inl" "$run/staging/*" "$round" "$fmt" "$outl" 2>>"$run/err.txt")
    LAST_REDUCE_RC=$?; LAST_REDUCE_ERR="$run/err.txt"; LAST_RUN_DIR="$run"
}
LAST_TALLY=""; LAST_REDUCE_RC=0; LAST_REDUCE_ERR=""; LAST_RUN_DIR=""

# ---------------------------------------------------------------------------
# Shared fixture constants — path/anchor/category for all test entries.
# ---------------------------------------------------------------------------
TP="bin/concern-ledger"
TA_REJ="cl_reject"; TA_OPEN="cl_tally"; TA_REMENTIONED="cl_reduce"
TCAT="correctness"; TPROD="review-code-codex"
TFMT_REDUCE="feat-2344-test"    # custom format: single-producer allowed
TFMT_MAIN="review-security-shared"
TSID_MAIN="rej-main-test"; TSID_REDUCE="rej-reduce-test"

TEXT_REJ="concern scheduled for rejection in feature-2344 tests"
TEXT_OPEN="another concern that remains open throughout testing"
TEXT_REMENTED="concern that codex re-mentions after it was rejected"

SLOT_REJ=$(cl cl_slot "$TP" "$TA_REJ" "$TCAT")
DISC_REJ=$(cl cl_discrim "$TEXT_REJ")
SLOT_OPEN=$(cl cl_slot "$TP" "$TA_OPEN" "$TCAT")
DISC_OPEN=$(cl cl_discrim "$TEXT_OPEN")
SLOT_REMENTIONED=$(cl cl_slot "$TP" "$TA_REMENTIONED" "$TCAT")
DISC_REMENTIONED=$(cl cl_discrim "$TEXT_REMENTED")

# ---------------------------------------------------------------------------
# C1: reject --ledger L --id C1 --reason R → exit 0, STATE=rejected, FLAGS has
#   'rejected', and all other 10 fields are unchanged (round-trip contract).
#   Pre-impl: exit 2 (unknown subcommand) → FAIL on exit-code assert (correct red).
# ---------------------------------------------------------------------------
echo ""
echo "--- C1: reject sets STATE=rejected, FLAGS has rejected, other fields preserved ---"

C1_W="$TMPDIR_BASE/c1"; mkdir -p "$C1_W"
C1_LED="$C1_W/ledger.txt"
mk_ledger "$C1_LED" "$TFMT_MAIN" "$TSID_MAIN" 1
add_entry "$C1_LED" C1 HIGH open 1 1 "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" - "$TEXT_REJ"
add_entry "$C1_LED" C2 MEDIUM open 1 1 "$SLOT_OPEN" "$DISC_OPEN" "$TPROD" "$TPROD" - "$TEXT_OPEN"

C1_C2_BEFORE="$(grep -m1 '^C2|' "$C1_LED" 2>/dev/null)"

C1_RC=0
run_cli reject --ledger "$C1_LED" --id C1 --reason "intentional test rejection" \
    >/dev/null 2>&1 || C1_RC=$?

assert_eq "C1: exit 0 on success"        "0"          "$C1_RC"
assert_eq "C1: STATE is rejected"        "rejected"   "$(entry_field "$C1_LED" C1 $F_STATE)"
assert_contains "C1: FLAGS has 'rejected'" "rejected" "$(entry_field "$C1_LED" C1 $F_FLAGS)"

# Round-trip: the 9 non-state/non-flags fields must be unchanged
assert_eq_nz "C1 rt: SEV preserved"       "HIGH"       "$(entry_field "$C1_LED" C1 $F_SEV)"
assert_eq_nz "C1 rt: FIRST preserved"     "1"          "$(entry_field "$C1_LED" C1 $F_FIRST)"
assert_eq_nz "C1 rt: LAST preserved"      "1"          "$(entry_field "$C1_LED" C1 $F_LAST)"
assert_eq_nz "C1 rt: SLOT preserved"      "$SLOT_REJ"  "$(entry_field "$C1_LED" C1 $F_SLOT)"
assert_eq_nz "C1 rt: DISCRIM preserved"   "$DISC_REJ"  "$(entry_field "$C1_LED" C1 $F_DISCRIM)"
assert_eq_nz "C1 rt: ORIGIN preserved"    "$TPROD"     "$(entry_field "$C1_LED" C1 $F_ORIGIN)"
assert_eq_nz "C1 rt: PRODUCERS preserved" "$TPROD"     "$(entry_field "$C1_LED" C1 $F_PRODUCERS)"
assert_eq_nz "C1 rt: TEXT preserved"      "$TEXT_REJ"  "$(entry_text  "$C1_LED" C1)"

C1_C2_AFTER="$(grep -m1 '^C2|' "$C1_LED" 2>/dev/null)"
assert_eq "C1: non-target C2 byte-for-byte unchanged" "$C1_C2_BEFORE" "$C1_C2_AFTER"

# ---------------------------------------------------------------------------
# C2: reject nonexistent ID → nonzero exit, ledger byte-for-byte unchanged.
#   Pre-impl: exit 2 (unknown subcommand) + ledger untouched → both checks PASS.
# ---------------------------------------------------------------------------
echo ""
echo "--- C2: reject nonexistent ID → nonzero, ledger unchanged ---"

C2_W="$TMPDIR_BASE/c2"; mkdir -p "$C2_W"
C2_LED="$C2_W/ledger.txt"
mk_ledger "$C2_LED" "$TFMT_MAIN" "$TSID_MAIN" 1
add_entry "$C2_LED" C1 HIGH open 1 1 "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" - "$TEXT_REJ"

C2_BEFORE="$(cat "$C2_LED" 2>/dev/null)"
C2_RC=0
run_cli reject --ledger "$C2_LED" --id C999 --reason "bad id test" \
    >/dev/null 2>&1 || C2_RC=$?

if [ "$C2_RC" -eq 0 ]; then fail "C2: nonexistent ID should be nonzero, got 0"
else pass "C2: nonexistent ID → nonzero exit ($C2_RC)"
fi
assert_eq "C2: ledger unchanged after bad-id reject" "$C2_BEFORE" "$(cat "$C2_LED" 2>/dev/null)"

# ---------------------------------------------------------------------------
# C3: --id pointing to a real entry, --reason absent → exit 2, C1 NOT rejected.
#   Double-assert (exit code + ledger unchanged) distinguishes from cases where
#   the implementation writes STATE=rejected and then exits 2 (wrong behaviour).
#   Pre-impl: exit 2 + ledger untouched → both PASS (acknowledged limitation).
# ---------------------------------------------------------------------------
echo ""
echo "--- C3: --reason absent → exit 2, ledger row not rejected ---"

C3_W="$TMPDIR_BASE/c3"; mkdir -p "$C3_W"
C3_LED="$C3_W/ledger.txt"
mk_ledger "$C3_LED" "$TFMT_MAIN" "$TSID_MAIN" 1
add_entry "$C3_LED" C1 HIGH open 1 1 "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" - "$TEXT_REJ"

C3_BEFORE="$(cat "$C3_LED" 2>/dev/null)"
C3_RC=0
run_cli reject --ledger "$C3_LED" --id C1 >/dev/null 2>&1 || C3_RC=$?

assert_eq "C3: exit code is 2 (usage/missing-arg)"           "2"     "$C3_RC"
assert_eq "C3: C1 STATE not changed (still open)"            "open"  "$(entry_field "$C3_LED" C1 $F_STATE)"
assert_eq "C3: ledger byte-for-byte unchanged"                "$C3_BEFORE" "$(cat "$C3_LED" 2>/dev/null)"

# ---------------------------------------------------------------------------
# C4: rejected concern re-mentioned by codex stays rejected (#2185 regression).
#   Ledger fixture has C1 with STATE=rejected (manual, bypassing CLI for now).
#   cl_reduce currently sets STATE=open for any touched entry → FAIL (correct red).
# ---------------------------------------------------------------------------
echo ""
echo "--- C4: re-mentioned rejected concern stays rejected (#2185 regression) ---"

C4_W="$TMPDIR_BASE/c4"; mkdir -p "$C4_W"
C4_LED_IN="$C4_W/in.txt"; C4_LED_OUT="$C4_W/out.txt"; C4_DELTA="$C4_W/delta.txt"

mk_ledger "$C4_LED_IN" "$TFMT_REDUCE" "$TSID_REDUCE" 1
add_entry "$C4_LED_IN" C1 HIGH rejected 1 1 \
    "$SLOT_REMENTIONED" "$DISC_REMENTIONED" "$TPROD" "$TPROD" - "$TEXT_REMENTED"

# Delta explicitly re-references C1 (ID-bound, simulates codex re-mention)
mk_delta_report "$C4_DELTA" \
    "$(anchored HIGH C1 "$TP" "$TA_REMENTIONED" "$TCAT" "$TEXT_REMENTED")"

reduce_round "$C4_LED_IN" "$C4_LED_OUT" 1 "$TFMT_REDUCE" \
    "$TPROD@COMPLETE@$C4_DELTA"

assert_eq "C4: reduce exits 0" "0" "$LAST_REDUCE_RC"
assert_eq "C4: re-mentioned rejected stays rejected" \
    "rejected" "$(entry_field "$C4_LED_OUT" C1 $F_STATE)"
assert_not_contains "C4: FLAGS have no 'reopened'" \
    "reopened" "$(entry_field "$C4_LED_OUT" C1 $F_FLAGS)"

# ---------------------------------------------------------------------------
# C5: rejected entry absent from round: not staled, tally has rejected=1.
#   a/b pass pre-impl (absent loop skips non-open entries already).
#   c FAILS pre-impl (cl_tally missing 'rejected=N' count) — correct red.
# ---------------------------------------------------------------------------
echo ""
echo "--- C5: rejected absent: not staled, tally rejected=1 ---"

C5_W="$TMPDIR_BASE/c5"; mkdir -p "$C5_W"
C5_LED_IN="$C5_W/in.txt"; C5_LED_OUT="$C5_W/out.txt"; C5_DELTA="$C5_W/delta.txt"

mk_ledger "$C5_LED_IN" "$TFMT_REDUCE" "$TSID_REDUCE" 1
add_entry "$C5_LED_IN" C1 HIGH rejected 1 1 \
    "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" - "$TEXT_REJ"
add_entry "$C5_LED_IN" C2 MEDIUM open 1 1 \
    "$SLOT_OPEN" "$DISC_OPEN" "$TPROD" "$TPROD" - "$TEXT_OPEN"

# Delta re-mentions only C2; C1 is absent and enters the absent loop
mk_delta_report "$C5_DELTA" \
    "$(anchored MEDIUM C2 "$TP" "$TA_OPEN" "$TCAT" "$TEXT_OPEN")"

reduce_round "$C5_LED_IN" "$C5_LED_OUT" 1 "$TFMT_REDUCE" \
    "$TPROD@COMPLETE@$C5_DELTA"

assert_eq "C5: reduce exits 0" "0" "$LAST_REDUCE_RC"
assert_eq  "C5a: absent rejected entry STATE stays 'rejected'" \
    "rejected" "$(entry_field "$C5_LED_OUT" C1 $F_STATE)"
assert_not_contains "C5b: absent rejected FLAGS have no 'stale'" \
    "stale" "$(entry_field "$C5_LED_OUT" C1 $F_FLAGS)"

C5_TALLY_RC=0
C5_TALLY="$(run_cli tally --ledger "$C5_LED_OUT" 2>/dev/null)" || C5_TALLY_RC=$?
assert_eq      "C5: tally exits 0"              "0"           "$C5_TALLY_RC"
assert_contains "C5c: tally contains 'rejected=1'" "rejected=1" "$C5_TALLY"
assert_not_contains "C5d: rejected not counted in open_high" "open_high=1" "$C5_TALLY"
assert_contains "C5e: C2 counted as open_medium=1" "open_medium=1" "$C5_TALLY"

# ---------------------------------------------------------------------------
# C6: #unparsed / #merged-alt meta lines preserved byte-for-byte after reject.
#   Pre-impl: reject exits 2 + ledger unchanged → meta lines present (PASS).
#   Post-impl regression guard: reject must write the entry without losing meta.
# ---------------------------------------------------------------------------
echo ""
echo "--- C6: meta lines preserved after reject ---"

C6_W="$TMPDIR_BASE/c6"; mkdir -p "$C6_W"
C6_LED="$C6_W/ledger.txt"
mk_ledger "$C6_LED" "$TFMT_MAIN" "$TSID_MAIN" 1
add_entry "$C6_LED" C1 HIGH open 1 1 "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" - "$TEXT_REJ"
printf '#unparsed|raw concern text that could not be parsed\n' >> "$C6_LED"
printf '#merged-alt|C1|alternative wording of the same concern\n' >> "$C6_LED"

C6_UNPARSED_BEFORE="$(grep '^#unparsed|' "$C6_LED" 2>/dev/null)"
C6_MERGEDALT_BEFORE="$(grep '^#merged-alt|' "$C6_LED" 2>/dev/null)"

C6_RC=0
run_cli reject --ledger "$C6_LED" --id C1 --reason "meta preservation test" \
    >/dev/null 2>&1 || C6_RC=$?

C6_UNPARSED_AFTER="$(grep '^#unparsed|' "$C6_LED" 2>/dev/null)"
C6_MERGEDALT_AFTER="$(grep '^#merged-alt|' "$C6_LED" 2>/dev/null)"

if [ "$C6_RC" -eq 0 ]; then pass "C6: reject exit 0 (implementation present)"
else pass "C6: reject did not exit 0 (rc=$C6_RC), verifying meta lines still intact"
fi

assert_eq "C6: #unparsed line byte-for-byte preserved" \
    "$C6_UNPARSED_BEFORE"  "$C6_UNPARSED_AFTER"
assert_eq "C6: #merged-alt line byte-for-byte preserved" \
    "$C6_MERGEDALT_BEFORE" "$C6_MERGEDALT_AFTER"

# After a successful reject, C1 STATE must be 'rejected' AND meta present
if [ "$C6_RC" -eq 0 ]; then
    assert_eq "C6: C1 STATE is rejected after meta-preserving reject" \
        "rejected" "$(entry_field "$C6_LED" C1 $F_STATE)"
fi

# ---------------------------------------------------------------------------
# C7: finalize over an all-rejected ledger. The unresolved-concerns/v1 artifact
#   excludes rejected concerns from `concerns` (plan §175) yet counts them under
#   a new counts."rejected" key (plan §176/§306). finalize.sh already runs; the
#   counter is RED until change 3 adds it at finalize.sh L157/L195-196.
# ---------------------------------------------------------------------------
echo ""
echo "--- C7: finalize all-rejected → excluded from concerns, counted as rejected ---"

C7_W="$TMPDIR_BASE/c7"; C7_P="$C7_W/plans"; mkdir -p "$C7_P"
C7_SID="rej-final-all"; C7_FMT="$TFMT_MAIN"
C7_LED="$C7_P/${C7_SID}-${C7_FMT}-concern-ledger.txt"
mk_ledger "$C7_LED" "$C7_FMT" "$C7_SID" 1
add_entry "$C7_LED" C1 HIGH rejected 1 1 "$SLOT_REJ" "$DISC_REJ" "$TPROD" "$TPROD" rejected "$TEXT_REJ"

C7_RC=0; C7_OUT=""
C7_OUT="$(run_cli finalize --plans-dir "$C7_P" --session-id "$C7_SID" --format "$C7_FMT" \
    --round 1 --mode terminal --reason "loop ended" 2>/dev/null)" || C7_RC=$?
assert_eq "C7: finalize exits 0" "0" "$C7_RC"

if [ "$C7_RC" -eq 0 ] && [ -n "$C7_OUT" ] && [ -f "$C7_OUT" ]; then
    C7_J="$(cat "$C7_OUT")"
    assert_contains     "C7: artifact is unresolved-concerns/v1"        '"schema": "unresolved-concerns/v1"' "$C7_J"
    assert_not_contains "C7: rejected C1 absent from concerns array"    '"id": "C1"'     "$C7_J"
    assert_contains     "C7: open_high count is 0 (rejected not open)"  '"open_high": 0' "$C7_J"
    assert_contains     "C7: counts carry a rejected tally (RED until change 3)" '"rejected"' "$C7_J"
else
    fail "C7: finalize did not produce a readable artifact (rc=$C7_RC out=$(printf '%q' "$C7_OUT"))"
fi

# ---------------------------------------------------------------------------
# C8: finalize over a mixed rejected+open ledger. The open concern is carried
#   into `concerns`; the rejected one is excluded but still tallied. RED on the
#   rejected counter until change 3 (finalize.sh L157/L195-196).
# ---------------------------------------------------------------------------
echo ""
echo "--- C8: finalize mixed rejected/open → open carried, rejected excluded+counted ---"

C8_W="$TMPDIR_BASE/c8"; C8_P="$C8_W/plans"; mkdir -p "$C8_P"
C8_SID="rej-final-mix"; C8_FMT="$TFMT_MAIN"
C8_LED="$C8_P/${C8_SID}-${C8_FMT}-concern-ledger.txt"
mk_ledger "$C8_LED" "$C8_FMT" "$C8_SID" 1
add_entry "$C8_LED" C1 HIGH   rejected 1 1 "$SLOT_REJ"  "$DISC_REJ"  "$TPROD" "$TPROD" rejected "$TEXT_REJ"
add_entry "$C8_LED" C2 MEDIUM open     1 1 "$SLOT_OPEN" "$DISC_OPEN" "$TPROD" "$TPROD" -        "$TEXT_OPEN"

C8_RC=0; C8_OUT=""
C8_OUT="$(run_cli finalize --plans-dir "$C8_P" --session-id "$C8_SID" --format "$C8_FMT" \
    --round 1 --mode terminal --reason "loop ended" 2>/dev/null)" || C8_RC=$?
assert_eq "C8: finalize exits 0" "0" "$C8_RC"

if [ "$C8_RC" -eq 0 ] && [ -n "$C8_OUT" ] && [ -f "$C8_OUT" ]; then
    C8_J="$(cat "$C8_OUT")"
    assert_contains     "C8: open C2 present in concerns"        '"id": "C2"'        "$C8_J"
    assert_contains     "C8: C2 recorded with open state"        '"state": "open"'   "$C8_J"
    assert_not_contains "C8: rejected C1 absent from concerns"   '"id": "C1"'        "$C8_J"
    assert_contains     "C8: open_medium count is 1"             '"open_medium": 1'  "$C8_J"
    assert_contains     "C8: counts carry a rejected tally (RED until change 3)" '"rejected"' "$C8_J"
else
    fail "C8: finalize did not produce a readable artifact (rc=$C8_RC out=$(printf '%q' "$C8_OUT"))"
fi

# ---------------------------------------------------------------------------
# C9: B2 DISCRIM binding — same prose re-raised in new round stays rejected
# ---------------------------------------------------------------------------
# When a concern is rejected and the exact same prose appears in a subsequent
# round (same DISCRIM), render-concerns-log must NOT reopen it as a new open
# concern — the carrier's rejected state takes precedence (RED until change 4/5).
echo "--- C9: B2 DISCRIM binding: re-raised same-text concern stays rejected ---"
C9_P="$TMPDIR_BASE/c9/plans"; mkdir -p "$C9_P"
C9_S="sess-c9"; C9_F="detail-plan"
C9_L="$C9_P/${C9_S}-${C9_F}-concern-ledger.txt"
C9_T="off-by-one error in index bounds check"
C9_D="$(discrim_of "$C9_T")"

# Round 1: open concern → render → reject
mk_ledger "$C9_L" "$C9_F" "$C9_S" "1"
add_entry "$C9_L" "C1" "HIGH" "open" "1" "1" "$(slot_of "$C9_T")" "$C9_D" "test" "codex" "-" "$C9_T"
run_cli render-concerns-log --plans-dir "$C9_P" --session-id "$C9_S" --format "$C9_F" >/dev/null 2>&1 || true
run_cli reject --plans-dir "$C9_P" --session-id "$C9_S" --format "$C9_F" \
    --id "C1" --reason "false positive — bounds verified" >/dev/null 2>&1 || true

# Round 2: begin-round resets cycle, re-add same text (same DISCRIM)
run_cli begin-round --plans-dir "$C9_P" --session-id "$C9_S" --format "$C9_F" \
    --round 2 >/dev/null 2>&1 || true
mk_ledger "$C9_L" "$C9_F" "$C9_S" "2"
add_entry "$C9_L" "C1" "HIGH" "open" "2" "2" "$(slot_of "$C9_T")" "$C9_D" "test" "codex" "-" "$C9_T"

C9_RC=0; C9_OUT=""
C9_OUT="$(run_cli render-concerns-log --plans-dir "$C9_P" --session-id "$C9_S" \
    --format "$C9_F" 2>/dev/null)" || C9_RC=$?

if [[ "$C9_RC" -eq 0 ]] && [[ -n "$C9_OUT" ]] && [[ -f "$C9_OUT" ]]; then
    C9_CONTENT="$(cat "$C9_OUT")"
    assert_contains    "C9: DISCRIM still in carrier (anti-false-positive)" \
        "$C9_D" "$C9_CONTENT"
    assert_contains    "C9: REJECTED token present (B2 binding preserved, RED until change 4/5)" \
        "REJECTED" "$C9_CONTENT"
    # Rejected entry format: "- DISCRIM [HIGH] REJECTED text". Filter those lines out
    # before checking — only OPEN occurrences of DISCRIM [HIGH] should be absent.
    assert_eq "C9: same prose not reopened as open concern" "" \
        "$(printf '%s\n' "$C9_CONTENT" | grep -F "$C9_D [HIGH]" | grep -v 'REJECTED' || true)"
else
    fail "C9: render-concerns-log failed or produced no carrier after B2 re-raise (rc=$C9_RC)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -eq 0 ]]; then echo "All tests passed."; exit 0; fi
exit 1
