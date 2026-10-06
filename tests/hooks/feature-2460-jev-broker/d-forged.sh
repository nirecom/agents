#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, broker, latency, untrusted-claim-content, unlogged-record, forged-claim, resolve-step, notes-session-binding, scope:issue-specific, pwsh-not-required
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after c-claim.sh (not
# standalone): Jev latency, forged claim / unlogged content, and resolveStep's notes sid.

echo "=== Jev latency is kept for every result after a completed query POST, null otherwise ==="
case_begin "b-query-jev-latency-after-completed-post" "hooks/lib/jev/broker.js"
# jl_row <tag> <mode-json> <expected status|latency>: the hand-off and the logged record agree.
jl_row() {
  fx_new "b-jl-$1"
  mock_mode "$2"
  check "$1: queryShadow jev status|latency_ms" "$3" "$(bp qt toolu_b_jl)"
  check "$1: the logged record carries the same latency" "${3#*|}" \
    "$(bp rt toolu_b_jl > /dev/null; rq toolu_b_jl 'r && (r.jev.latency_ms === null ? "null" : Number.isFinite(r.jev.latency_ms) && r.jev.latency_ms >= 0 ? "finite" : "bad")')"
}
jl_row ok '{}' 'ok|finite'
jl_row lowconf '{"answers":{"S2-architecture":0.6}}' 'low-confidence|finite'
jl_row unmappable '{"systemone":"missing"}' 'unmappable|finite'
jl_row http500 '{"systemone":"http:500"}' 'http-error|null'
jl_row badjson '{"systemone":"badjson"}' 'bad-response|null'  # an outage (breaker-counted), so no latency, unlike unmappable
fx_new b-jl-breaker
mock_mode '{}'
mkdir -p "$JEVDIR/sid-1"
printf '%s' '{"consecutive_failures":3,"open_until_ms":9999999999999,"last_failure_status":"timeout"}' > "$JEVDIR/sid-1/breaker.json"
check "breaker open: status breaker-open, latency null, no Jev request" "breaker-open|null|0" "$(bp qt toolu_b_jl)|$(mock_total)"
case_end

echo "=== a claim's jev / step / stage / input are file content: only validated values are logged ==="
FORGED_JEV='{"status":"ok","answer":"S1-multi-file","http_status":999,"probabilities":{"S1-multi-file":7,"EVIL-KEY-MARK-2460":0.5},"min_confidence":2,"latency_ms":1e12,"model":"EVIL MODEL MARK-2460;","input_tokens":-5,"est_cost_usd":1e9}'
# forge <tid> <jev-json>: a real pending whose jev, step, stage and input are overwritten.
forge() {
  local f="$JEVDIR/sid-1/pending/$1.json"
  bp qt "$1" > /dev/null
  hq json-set "$(np "$f")" jev "$2"
  hq json-set "$(np "$f")" step '"../EVIL-STEP-MARK-2460"'
  hq json-set "$(np "$f")" stage '"EVIL-STAGE-MARK-2460"'
  hq json-set "$(np "$f")" input '{"bytes":-1,"sha256":"EVIL-SHA-MARK-2460","truncated":"yes","sources":["EVIL-SRC-MARK-2460"]}'
}
SANE_JEV='r && [r.jev.status, r.jev.answer, r.jev.http_status, Object.keys(r.jev.probabilities).join(","), r.jev.probabilities["S1-multi-file"], r.jev.min_confidence, r.jev.latency_ms, r.jev.model, r.jev.input_tokens, r.jev.est_cost_usd].map(String).join("|")'
SANE_EXP="ok|S1-multi-file|null|$SIGNAL_CSV|null|null|null|null|null|null"
SANE_REST='r && [String(r.step), r.stage, JSON.stringify(r.input)].join("|")'
SANE_REST_EXP='null|unknown|{"bytes":0,"sha256":null,"truncated":false,"sources":[]}'
case_begin "b-forged-claim-sanitized" "hooks/lib/jev/broker.js"
fx_new b-forged
mock_mode '{}'
forge toolu_b_fo "$FORGED_JEV"
forge toolu_b_fs '{"status":"PWNED-STATUS-MARK-2460","answer":"S1-multi-file"}'
for _t in toolu_b_fo toolu_b_fs; do mv "$JEVDIR/sid-1/pending/$_t.json" "$JEVDIR/sid-1/pending/$_t.claimed-99999"; done
forge toolu_b_fp "$FORGED_JEV"
check "claim path: the forged pending pairs; out-of-range jev fields are null, extra probability keys dropped" "record|1|$SANE_EXP" \
  "$(bp rt toolu_b_fp)|$(rq toolu_b_fp 'recs.length')|$(rq toolu_b_fp "$SANE_JEV")"
check "claim path: forged step, stage and input are not logged" "$SANE_REST_EXP" "$(rq toolu_b_fp "$SANE_REST")"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "fixture: both forged orphan claims are swept" "2|0" "$(bp sweep)|$(pending_count)"
check "orphan with out-of-range jev fields: sanitized jev, llm missing" "$SANE_EXP|missing" \
  "$(rq toolu_b_fo "$SANE_JEV")|$(rq toolu_b_fo 'r && r.llm.status')"
check "orphan with a forged jev status: recorded as jev not-run" "not-run|null|not-run" \
  "$(rq toolu_b_fs 'r && [r.jev.status, String(r.jev.answer), r.fallback_reason].join("|")')"
for _t in toolu_b_fo toolu_b_fs; do check "$_t: forged step, stage and input are not logged" "$SANE_REST_EXP" "$(rq "$_t" "$SANE_REST")"; done
check "no forged marker reaches the log (3 records)" "3|absent" "$(hq qa "$(np "$LOG")" 'recs.length')|$(grep_absent MARK-2460 "$LOG")"
case_end

case_begin "b-orphan-claim-executor-model-validated" "hooks/lib/jev/broker.js"
fx_new b-forged-model
mock_mode '{}'
for _m in bad:'"EVIL MODEL MARK-2460;"' ok:'"sonnet"'; do
  bp qt "toolu_b_em_${_m%%:*}" > /dev/null
  hq json-set "$(np "$JEVDIR/sid-1/pending/toolu_b_em_${_m%%:*}.json")" executor_model "${_m#*:}"
done
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "both orphans swept: a forged executor_model is logged as unknown, a valid one kept" "2|missing|unknown|missing|sonnet|absent" \
  "$(bp sweep)|$(rq toolu_b_em_bad 'r && [r.llm.status, r.llm.executor_model].join("|")')|$(rq toolu_b_em_ok 'r && [r.llm.status, r.llm.executor_model].join("|")')|$(grep_absent MARK-2460 "$LOG")"
case_end

echo "=== a post with no claim whose append failed leaves one unlogged record for the sweep ==="
case_begin "b-unlogged-record-swept-once" "hooks/lib/jev/broker.js"
fx_new b-unlogged
mock_mode '{}'
mkdir -p "$LOG"
check "log unwritable, no pending: the record is returned and exactly one .unlogged- file is left" "record|1|1" \
  "$(bp rt toolu_b_ul)|$(pend_n 'toolu_b_ul.unlogged-*')|$(pending_count)"
UL_FILE="$(find "$JEVDIR/sid-1/pending" -name 'toolu_b_ul.unlogged-*' 2>/dev/null | head -n 1)"
UL_TS="$(hq json-get "$(np "$UL_FILE")" record_ts)"
check "a sweep before the log is writable keeps it" "1|1" "$(hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive; bp sweep)|$(pending_count)"
rmdir "$LOG"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "log writable: the sweep appends it once with the observed llm block and its own timestamp, then deletes it" \
  "1|1|ok|S1-multi-file|true|null|not-run|true|0" \
  "$(bp sweep)|$(rq toolu_b_ul 'recs.length + "|" + (r && [r.llm.status, r.llm.answer, /^[A-Za-z0-9._-]+$/.test(r.llm.executor_model), String(r.llm.latency_ms), r.jev.status, r.ts === new Date('"$UL_TS"').toISOString()].join("|"))')|$(pending_count)"
check "a further sweep records nothing more" "0|1" "$(bp sweep)|$(rq toolu_b_ul 'recs.length')"
case_end

case_begin "b-forged-unlogged-sanitized" "hooks/lib/jev/broker.js"
fx_new b-unlogged-forged
mkdir -p "$JEVDIR/sid-1/pending"
_n=0
for _ts in '"EVIL-TS-MARK-2460"' '1e20'; do
  _n=$((_n + 1))
  printf '%s' '{"v":1,"point":"complexity-judge","step":"../EVIL-STEP-MARK-2460","jev":{"status":"PWNED-MARK-2460"},"input":{"sha256":"EVIL-SHA-MARK-2460"},"executor_model":"EVIL MODEL MARK-2460","llm_observed":{"status":"ok","answer":"S9-EVIL-MARK-2460","latency_ms":5},"record_ts":'"$_ts"'}' \
    > "$JEVDIR/sid-1/pending/toolu_b_ulf$_n.unlogged-123-456"
done
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "both forged unlogged files are swept and removed" "2|0" "$(bp sweep)|$(pending_count)"
for _t in toolu_b_ulf1 toolu_b_ulf2; do
  check "$_t: llm missing, jev not-run, step null, model unknown, ts a valid recent date" "missing|null|not-run|null|unknown|true" \
    "$(rq "$_t" 'r && [r.llm.status, String(r.llm.answer), r.jev.status, String(r.step), r.llm.executor_model, Math.abs(Date.now() - Date.parse(r.ts)) < 600000].join("|")')"
done
check "no forged marker reaches the log" "2|absent" "$(hq qa "$(np "$LOG")" 'recs.length')|$(grep_absent MARK-2460 "$LOG")"
case_end

echo "=== resolveStep: a notes Session-ID equal to the hook's never lends a step (notes sid|own step|step|step again|stage) ==="
case_begin "b-resolve-step-notes-sid-is-hook-sid" "hooks/lib/jev/broker.js"
fx_new b-rs-self
check "notes sid is the hook sid, bound to the cwd, every step settled: null twice, stage unknown" \
  "rs-self|null|null|null|unknown" "$(bp resolve-step "$(np "$FX/cwd")" rs-self rs-self settled)"
fx_new b-rs-self-nostate
check "notes sid is the hook sid and it has no workflow state: null twice, stage unknown" \
  "null|null|null|null|unknown" "$(bp resolve-step "$(np "$FX/cwd")" rs-none rs-none none)"
fx_new b-rs-other
check "control: a different bound notes sid at clarify_intent lends its step to a stateless hook sid" \
  "rs-notes|null|clarify_intent|clarify_intent|cos1" "$(bp resolve-step "$(np "$FX/cwd")" rs-notes rs-hook clarify)"
case_end
