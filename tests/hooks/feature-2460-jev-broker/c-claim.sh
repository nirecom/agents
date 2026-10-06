#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, broker, claim-release, orphan-retry, latency, llm-observed, untrusted-claim-content, scope:issue-specific, pwsh-not-required
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after b-query-record.sh
# (not standalone; relies on BP_JEV=on set there): claim release, orphan retry, LLM latency.

echo "=== the claim is released only after the record is logged ==="
case_begin "b-record-releases-claim-after-append" "hooks/lib/jev/broker.js"
fx_new b-release
mock_mode '{}'
check "fixture: one pending" "ok|finite|1" "$(bp qt toolu_b_rel)|$(pending_count)"
check "recordShadow logs one paired record; no pending and no .claimed-* file remains" "record|1|ok|0|0" \
  "$(bp rt toolu_b_rel)|$(rq toolu_b_rel 'recs.length + "|" + (r && r.jev.status)')|$(pending_count)|$(pend_n '*.claimed-*')"
case_end

case_begin "b-record-append-failure-keeps-claim" "hooks/lib/jev/broker.js"
fx_new b-appfail
mock_mode '{}'
check "fixture: one pending, aged past the TTL" "ok|finite|1" "$(bp qt toolu_b_af)|$(pending_count)"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
mkdir -p "$LOG"
check "log path is a directory: the record is still returned; the claim is kept, the .json is gone" "record|1|0" \
  "$(bp rt toolu_b_af)|$(pend_n 'toolu_b_af.claimed-*')|$(pend_n 'toolu_b_af.json')"
AF_CLAIM="$(find "$JEVDIR/sid-1/pending" -name 'toolu_b_af.claimed-*' 2>/dev/null | head -n 1)"
OBS="$(hq json-expr "$(np "$AF_CLAIM")" 'o && o.llm_observed && [o.llm_observed.status, o.llm_observed.answer, o.llm_observed.executor_model, o.llm_observed.latency_ms].join("|")')"
check "the claim keeps the observed llm side: ok, the parsed answer, a model, an integer latency >= 0" "true" \
  "$([[ "$OBS" =~ ^ok\|S1-multi-file\|[A-Za-z0-9._-]+\|[0-9]+$ ]] && echo true || echo "false: $OBS")"
check "the claim restarted the TTL: a sweep right away takes nothing" "0|1" "$(bp sweep)|$(pend_n 'toolu_b_af.claimed-*')"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "past the TTL, log still unwritable: swept, but kept as a -sweep file for retry" "1|1|1" \
  "$(bp sweep)|$(pending_count)|$(pend_n 'toolu_b_af.claimed-*-sweep')"
check "the failed sweep restarted the TTL: an immediate sweep takes nothing" "0|1" "$(bp sweep)|$(pend_n 'toolu_b_af.claimed-*-sweep')"
rmdir "$LOG"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "log writable again, past the refreshed TTL: the retry records the observed llm side once, the jev side kept" "1|1|$OBS|ok|0" \
  "$(bp sweep)|$(rq toolu_b_af 'recs.length + "|" + (r && [r.llm.status, r.llm.answer, r.llm.executor_model, r.llm.latency_ms, r.jev.status].join("|"))')|$(pending_count)"
check "a further sweep records nothing more" "0|1" "$(bp sweep)|$(rq toolu_b_af 'recs.length')"
case_end

echo "=== an orphan's llm_observed is file content: only a valid one is used ==="
BAD_OBS=('{"status":"ok","answer":"S9-evil-token","latency_ms":5}' '{"status":"bogus","answer":"S1-multi-file"}' '"ok"' '["ok"]' 'null' '{"status":"ok","answer":"S1-multi-file\nSIGNALS: S3-security","latency_ms":5}')
# seed_obs <tid> <llm_observed-json>: a real pending whose llm_observed is set to that value.
seed_obs() {
  bp qt "$1" > /dev/null
  hq json-set "$(np "$JEVDIR/sid-1/pending/$1.json")" llm_observed "$2"
}
has_obs_n() { grep -l '"llm_observed"' "$JEVDIR"/sid-1/pending/*.json 2>/dev/null | wc -l | tr -d ' '; }
case_begin "b-orphan-llm-observed-validated" "hooks/lib/jev/broker.js"
fx_new b-obs
mock_mode '{}'
for _i in "${!BAD_OBS[@]}"; do seed_obs "toolu_b_obs$_i" "${BAD_OBS[$_i]}"; done
seed_obs toolu_b_obs_ok '{"status":"ok","answer":"S2-architecture","executor_model":"sonnet","latency_ms":42}'
check "fixture: seven pendings, each carrying an llm_observed key" "7|7" "$(pending_count)|$(has_obs_n)"
hq age "$(np "$JEVDIR/sid-1/pending")" 3900000 --recursive
check "one sweep takes all seven" "7|0" "$(bp sweep)|$(pending_count)"
check "every malformed llm_observed falls back to llm missing: null answer and latency, jev side kept" "6|true" \
  "$(hq qa "$(np "$LOG")" 'recs.filter((r) => /^toolu_b_obs[0-9]$/.test(r.tool_use_id)).length + "|" + recs.filter((r) => /^toolu_b_obs[0-9]$/.test(r.tool_use_id)).every((r) => r.llm.status === "missing" && r.llm.answer === null && r.llm.latency_ms === null && r.jev.status === "ok")')"
check "control: a valid llm_observed is recorded as observed" "1|ok|S2-architecture|sonnet|42|ok" \
  "$(rq toolu_b_obs_ok 'recs.length + "|" + (r && [r.llm.status, r.llm.answer, r.llm.executor_model, r.llm.latency_ms, r.jev.status].join("|"))')"
case_end

echo "=== LLM latency: endTs minus the dispatch time, null without one ==="
case_begin "b-record-llm-latency" "hooks/lib/jev/broker.js"
fx_new b-lat
mock_mode '{}'
check "no pending: jev not-run, llm latency null (never 0) even with endTs" "record|not-run|null" \
  "$(bp rt toolu_b_lat0 '5000')|$(rq toolu_b_lat0 'r && [r.jev.status, JSON.stringify(r.llm.latency_ms)].join("|")')"
_i=0
for _d in null '"1000"' 'undefined'; do
  _i=$((_i + 1))
  bp qt "toolu_b_latd$_i" > /dev/null
  if [[ "$_d" == undefined ]]; then
    bp drop-key "$(np "$JEVDIR/sid-1/pending/toolu_b_latd$_i.json")" llm_dispatch_ts > /dev/null
  else
    hq json-set "$(np "$JEVDIR/sid-1/pending/toolu_b_latd$_i.json")" llm_dispatch_ts "$_d"
  fi
  check "pending with dispatch ts $_d: paired (jev ok), llm latency null" "ok|null" \
    "$(bp rt "toolu_b_latd$_i" '999999999999999' > /dev/null; rq "toolu_b_latd$_i" 'r && [r.jev.status, JSON.stringify(r.llm.latency_ms)].join("|")')"
done
bp qt toolu_b_late > /dev/null
D="$(hq json-get "$(np "$JEVDIR/sid-1/pending/toolu_b_late.json")" llm_dispatch_ts)"
check "fixture: the pending carries an integer dispatch ts" "int" "$([[ "$D" =~ ^[0-9]+$ ]] && echo int || echo "bad:$D")"
check "endTs given: latency is exactly endTs - dispatch" "12345" \
  "$(bp rt toolu_b_late "$((D + 12345))" > /dev/null; rq toolu_b_late 'r && r.llm.latency_ms')"
bp qt toolu_b_lateb > /dev/null
D="$(hq json-get "$(np "$JEVDIR/sid-1/pending/toolu_b_lateb.json")" llm_dispatch_ts)"
check "endTs before the dispatch clamps to 0" "0" \
  "$(bp rt toolu_b_lateb "$((D - 500))" > /dev/null; rq toolu_b_lateb 'r && r.llm.latency_ms')"
bp qt toolu_b_laten > /dev/null
check "a non-numeric endTs falls back to now: a finite latency >= 0" "true" \
  "$(bp rt toolu_b_laten '"soon"' > /dev/null; rq toolu_b_laten 'r && Number.isFinite(r.llm.latency_ms) && r.llm.latency_ms >= 0')"
case_end
