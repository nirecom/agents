#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, bin/workflow/lib/jev-skip-adapter.js, hooks/lib/jev/two-stage/gate.js
# Tags: TL2, bin, jev, two-stage, skip-gate, threshold-by-answer, short-circuit, boundary-values, registry-data, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# per-direction thresholds and the short-circuit answer of outline-skip / detail-skip (registry
# defaults { true: 0.9, false: 0.7 }, short_circuit_answer false) against the complexity-judge
# defaults, and outcomes that change through registry data alone (resolveEntry swaps).

echo "=== jev-judge: skip thresholds and short circuit ==="
need_mod bin/workflow/jev-judge || return 0
need_mod bin/workflow/lib/jev-skip-adapter.js || return 0
. "$JJ_DIR/_skip-lib.sh"

# Float precision: conf = max(p, 1 - p) is compared inclusively against the direction's
# threshold. In IEEE-754 doubles 1 - 0.3 === 0.7 and 1 - 0.1 === 0.9 exactly (node:
# (1-0.3).toPrecision(17) = 0.69999999999999996 = (0.7).toPrecision(17)), so the adopted
# boundaries p = 0.3 / 0.9 / 0.1 hold with or without CONFIDENCE_EPSILON (1e-9), and the held
# neighbours (1 - 0.31 = 0.69, 0.89, 1 - 0.11 = 0.89 for the true side) sit 0.01 away, far
# outside the epsilon. A gate that compares with > instead of >= fails the 0.3 and 0.9 rows.

# gq <fixture> <target> <p1> <p2> [entry-extra]: fixture + mock (K1=p1, K2=p2) + query.
gq() { sk_fx "$1" "$2"; mock_p 0.5 "$K1" "$3" "$K2" "$4"; sk_query "$2" "${5:-}"; }
# cq <fixture> <entry-extra> <mock args...>: complexity-judge query at stage complexity.
cq() {
  local name="$1" ex="$2"; shift 2
  jj_fx "$name"; mock_p "$@"
  sp query "{\"sid\":\"$SID\",\"point\":\"complexity-judge\",\"stage\":\"complexity\",\"entry\":{\"mode\":\"production\"${ex:+,$ex}}}"
  TICKET="$(kv TICKET)"
}
THR_SKIP='{"true":0.9,"false":0.7}|false'
thr() { lq "$TICKET" 'r && JSON.stringify(r.threshold)+"|"+String(r.short_circuit_answer)'; }

case_begin "jj-skip-true-direction-boundary" "bin/workflow/lib/jev-skip-adapter.js"
for tg in outline detail; do
  for p in 0.69 0.7 0.89; do
    gq "g-th-$tg-$p" "$tg" "$p" "$p"
    check "$tg all p=$p: held (conf < 0.9) -> RESULT=need-subagent" "need-subagent" "$(kv RESULT)"
    check "$tg all p=$p: both keys delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
    check "$tg all p=$p: the backup is plan-skip-judge" "plan-skip-judge" "$(kv SUBAGENT)"
  done
  gq "g-th-$tg-0.9" "$tg" 0.9 0.9
  check "$tg all p=0.9: adopted -> RESULT=final" "final" "$(kv RESULT)"
  check "$tg all p=0.9: SUBAGENT=-" "-" "$(kv SUBAGENT)"
  sk_fin
  check "$tg all p=0.9: SKIP=true" "true" "$(kv SKIP)"
  check "$tg all p=0.9: ADOPTED=jev" "jev" "$(kv ADOPTED)"
  check "$tg all p=0.9: threshold and short_circuit_answer recorded" "$THR_SKIP" "$(thr)"
  check "$tg all p=0.9: skip_judgment source jev" "jev" "$(sjq "$tg" 'sj && sj.judgment_source')"
done
case_end

case_begin "jj-skip-false-direction-boundary" "bin/workflow/lib/jev-skip-adapter.js"
for tg in outline detail; do
  gq "g-fh-$tg" "$tg" 0.31 0.5
  check "$tg K1 p=0.31: held (conf 0.69 < 0.7) -> RESULT=need-subagent" "need-subagent" "$(kv RESULT)"
  check "$tg K1 p=0.31: both keys delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
  sk_fin
  check "$tg K1 p=0.31: short_circuited false" "false" "$(lq "$TICKET" 'r && String(r.short_circuited)')"
  for p in 0.3 0.11 0.1; do
    gq "g-fa-$tg-$p" "$tg" "$p" 0.5
    check "$tg K1 p=$p: adopted false -> RESULT=final" "final" "$(kv RESULT)"
    check "$tg K1 p=$p: SUBAGENT DELEGATED ANSWER_FILE all '-'" "-|-|-" "$(kv SUBAGENT)|$(kv DELEGATED)|$(kv ANSWER_FILE)"
    sk_fin
    check "$tg K1 p=$p: SKIP=false" "false" "$(kv SKIP)"
    check "$tg K1 p=$p: ADOPTED=jev" "jev" "$(kv ADOPTED)"
    check "$tg K1 p=$p: llm_needed false, short_circuited true" "false|true" \
      "$(lq "$TICKET" 'r && r.llm_needed+"|"+r.short_circuited')"
    check "$tg K1 p=$p: unjudged_keys is K2 only" "[\"$K2\"]" "$(lq "$TICKET" 'r && JSON.stringify(r.unjudged_keys)')"
    check "$tg K1 p=$p: skip_judgment fills the unjudged key false" "$(sk_conds false false)" "$(sk_sj_conds "$tg")"
    check "$tg K1 p=$p: threshold and short_circuit_answer recorded" "$THR_SKIP" "$(thr)"
  done
done
case_end

case_begin "jj-skip-adopted-true-no-short-circuit" "bin/workflow/lib/jev-skip-adapter.js"
for tg in outline detail; do
  gq "g-tn-$tg" "$tg" 0.95 0.5
  check "$tg K1 p=0.95, K2 p=0.5: an adopted true does not short-circuit" "need-subagent" "$(kv RESULT)"
  check "$tg K1 p=0.95: only K2 delegated" "$(keyset "$K2")" "$(keyset "$(kv DELEGATED)")"
done
case_end

case_begin "jj-skip-asymmetric-short-circuit" "bin/workflow/lib/jev-skip-adapter.js"
# A symmetric 0.9/0.9 rule would hold p=0.2 (conf 0.8); the shipped false side (0.7) adopts it.
for tg in outline detail; do
  gq "g-as-$tg" "$tg" 0.2 0.5
  check "$tg K1 p=0.2: short circuit (no symmetric 0.9 rule left)" "final" "$(kv RESULT)"
  sk_fin
  check "$tg K1 p=0.2: SKIP=false, short_circuited true" "false|true" \
    "$(kv SKIP)|$(lq "$TICKET" 'r && String(r.short_circuited)')"
done
case_end

case_begin "jj-skip-all-delegated-085" "bin/workflow/lib/jev-skip-adapter.js"
for tg in outline detail; do
  gq "g-85-$tg" "$tg" 0.85 0.85
  check "$tg all p=0.85: both delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
  sk_answer "$(sk_line true true)"
  sk_fin
  check "$tg all p=0.85 + subagent true/true: SKIP=true, ADOPTED=llm" "true|llm" "$(kv SKIP)|$(kv ADOPTED)"
  check "$tg all p=0.85: llm_needed true" "true" "$(lq "$TICKET" 'r && String(r.llm_needed)')"
  check "$tg all p=0.85: skip_judgment source subagent" "subagent" "$(sjq "$tg" 'sj && sj.judgment_source')"
  check "$tg all p=0.85: threshold and short_circuit_answer recorded" "$THR_SKIP" "$(thr)"
done
case_end

case_begin "jj-complexity-defaults-contrast" "hooks/lib/jev/two-stage/gate.js"
cq g-cx "" 0.5 S2-architecture 0.25 S3-security 0.75 S5-breaking 0.65
check "complexity p=0.25 none / 0.75 adopted, 0.65 held: only S5 delegated" "s5_breaking" "$(keyset "$(kv DELEGATED)")"
check "complexity: RESULT=need-subagent" "need-subagent" "$(kv RESULT)"
jj finalize --session "$SID" --ticket "$TICKET"
check "complexity: short_circuited false (short_circuit_answer null)" "false" "$(lq "$TICKET" 'r && String(r.short_circuited)')"
check "complexity: threshold 0.7/0.7, short_circuit_answer null" '{"true":0.7,"false":0.7}|null' "$(thr)"
cq g-cx2 "" 0.5 S2-architecture 0.25
check "complexity S2 p=0.25 adopted none, others p=0.5: still need-subagent" "need-subagent" "$(kv RESULT)"
check "complexity S2 p=0.25: S3 and S5 delegated" "s3_security,s5_breaking" "$(keyset "$(kv DELEGATED)")"
case_end

case_begin "jj-registry-data-only-flips" "hooks/lib/jev/two-stage/gate.js"
SWAP='"confidence_threshold_by_answer":{"true":0.7,"false":0.9}'
gq g-sw1 detail 0.2 0.2 "$SWAP"
check "swapped thresholds, all p=0.2: held (false-side conf 0.8 < 0.9)" "need-subagent" "$(kv RESULT)"
check "swapped thresholds, all p=0.2: both delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
gq g-sw2 detail 0.75 0.75 "$SWAP"
check "swapped thresholds, all p=0.75: RESULT=final" "final" "$(kv RESULT)"
sk_fin
check "swapped thresholds, all p=0.75: SKIP=true" "true" "$(kv SKIP)"
check "swapped thresholds recorded from the ticket" '{"true":0.7,"false":0.9}' \
  "$(lq "$TICKET" 'r && JSON.stringify(r.threshold)')"
gq g-sca detail 0.2 0.5 '"short_circuit_answer":null'
check "detail short_circuit_answer null, K1 p=0.2: no short circuit" "need-subagent" "$(kv RESULT)"
check "detail short_circuit_answer null: only K2 delegated" "$(keyset "$K2")" "$(keyset "$(kv DELEGATED)")"
cq g-cxsc '"short_circuit_answer":false' 0.5 S2-architecture 0.25
check "complexity short_circuit_answer false, S2 p=0.25: short circuit" "final" "$(kv RESULT)"
jj finalize --session "$SID" --ticket "$TICKET"
check "complexity short circuit: S3 and S5 unjudged" "s3_security,s5_breaking" \
  "$(keyset "$(lq "$TICKET" 'r && (r.unjudged_keys||[]).join(",")')")"
case_end

case_begin "jj-skip-shadow-entry-delegates" "bin/workflow/lib/jev-skip-adapter.js"
gq g-shadow detail 0.99 0.01 '"mode":"shadow"'
check "shadow entry, p=0.99/0.01: both delegated" "$(keyset "$K1,$K2")" "$(keyset "$(kv DELEGATED)")"
sk_fin
check "shadow entry: short_circuited false, MODE=shadow" "false|shadow" \
  "$(lq "$TICKET" 'r && String(r.short_circuited)')|$(kv MODE)"
check "shadow entry: the Jev probabilities stay in the decision record" "1" \
  "$(lq "$TICKET" 'r && JSON.stringify(r.jev||null).includes("0.99") ? 1 : 0')"
case_end
