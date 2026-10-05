#!/usr/bin/env bash
# Tests: hooks/lib/jev/breaker.js, hooks/lib/jev/liveness.js, hooks/jev-shadow-pre.js, hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, circuit-breaker, liveness, time-travel-by-state-file, scope:issue-specific, pwsh-not-required, try-acquire, half-open, concurrency, bad-response, late-success, admitted-at

# A sick Jev must not add latency to every dispatch: three consecutive transport or HTTP
# failures open the per-session breaker for 10 minutes, and a successful /v1/models probe
# is cached for 10 minutes. Configuration gaps (no-key) and answers that merely fail the
# confidence bar are not outages and never count. Time moves by rewriting state files (C9).

# TL3 gap (what this test does NOT catch): wall-clock expiry in a long real session; the
# absolute epoch-ms fields rewritten here are the same ones a real clock would pass.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

# pre_n <sid> <tag> <n> [VAR=value ...]: run the pre hook n times with distinct tool_use_ids.
pre_n() {
  local sid="$1" tag="$2" n="$3" i
  shift 3
  for i in $(seq 1 "$n"); do
    mkpayload "$FX/io/pre-$tag-$i.json" pre "$sid" "toolu_f_${tag}_$i"
    run_hook pre "$FX/io/pre-$tag-$i.json" "$@"
  done
}
breaker_field() { hq json-get "$(np "$JEVDIR/$1/breaker.json")" "$2"; }

echo "=== three failures open the breaker ==="
case_begin "f-open-after-three-failures" "hooks/lib/jev/breaker.js"
fx_new f-open
SID="jev2460-f-open"
mock_mode '{"systemone":"http:500"}'
pre_n "$SID" fail 3
check "three failing dispatches send three queries" "3" "$(mock_count systemone)"
check "breaker.json counts 3 consecutive failures, last status http-error" "3|\"http-error\"" \
  "$(breaker_field "$SID" consecutive_failures)|$(breaker_field "$SID" last_failure_status)"
check "open_until_ms is about 10 minutes ahead" "true" \
  "$(hq json-expr "$(np "$JEVDIR/$SID/breaker.json")" 'o && (o.open_until_ms - now) > 540000 && (o.open_until_ms - now) <= 600000')"
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_f_fourth
check "the 4th dispatch sends no query" "3" "$(mock_count systemone)"
check "the 4th dispatch is recorded as breaker-open" "breaker-open|breaker-open" \
  "$(rq toolu_f_fourth 'r && [r.jev.status, r.fallback_reason].join("|")')"
case_end

case_begin "f-half-open-after-expiry" "hooks/lib/jev/breaker.js"
hq json-set "$(np "$JEVDIR/$SID/breaker.json")" open_until_ms "$(( $(hq now) - 1000 ))"
mock_mode '{}'
pre_n "$SID" reopen 1
check "an expired open_until_ms lets the next dispatch query again" "1" "$(mock_count systemone)"
check "the successful query resets the failure count" "0" "$(breaker_field "$SID" consecutive_failures)"
case_end

case_begin "f-success-resets-count" "hooks/lib/jev/breaker.js"
fx_new f-reset
SID="jev2460-f-reset"
mock_mode '{"systemone":"http:529"}'
pre_n "$SID" a 2
mock_mode '{}'
pre_n "$SID" b 1
mock_mode '{"systemone":"http:529"}'
pre_n "$SID" c 2
check "fail, fail, ok, fail, fail: the last two failures are still sent and count 2, not 4" "2|2" \
  "$(mock_count systemone)|$(breaker_field "$SID" consecutive_failures)"
case_end

echo "=== non-outage outcomes never count ==="
case_begin "f-no-key-not-counted" "hooks/lib/jev/breaker.js"
fx_new f-nokey
SID="jev2460-f-nokey"
mock_mode '{}'
pre_n "$SID" nokey 3 TYPESAFE_API_KEY=__unset__
pre_n "$SID" withkey 1
check "three no-key runs do not open the breaker: the keyed 4th run queries" "1" "$(mock_count systemone)"
case_end
case_begin "f-low-confidence-not-counted" "hooks/lib/jev/breaker.js"
fx_new f-lowc
SID="jev2460-f-lowc"
mock_mode '{"answers":{"S2-architecture":0.6}}'
pre_n "$SID" lowc 4
check "four low-confidence answers: all four queries sent" "4" "$(mock_count systemone)"
check "four low-confidence answers: the failure count stays 0" "0" "$(breaker_field "$SID" consecutive_failures)"
case_end

echo "=== a malformed answer set is an outage (bad-response) ==="
# ust <n>: jev.status of the n-th f-unmap hand-off.
ust() { hq json-expr "$(np "$JEVDIR/$SID/pending/toolu_f_unmap_$1.json")" 'o && o.jev.status'; }
case_begin "f-unmappable-counts-as-bad-response" "hooks/lib/jev/breaker.js"
fx_new f-unmap
SID="jev2460-f-unmap"
mock_mode '{"systemone":"missing"}'
pre_n "$SID" unmap 4
check "four unmappable answers: three queries sent, the 4th is held back by the open breaker" "3" "$(mock_count systemone)"
check "breaker.json counts 3 consecutive bad-response failures" '3|"bad-response"' \
  "$(breaker_field "$SID" consecutive_failures)|$(breaker_field "$SID" last_failure_status)"
check "the hand-offs keep unmappable for the three answered, breaker-open for the 4th" "unmappable|unmappable|unmappable|breaker-open" \
  "$(ust 1)|$(ust 2)|$(ust 3)|$(ust 4)"
case_end
case_begin "f-unmappable-then-ok-resets" "hooks/lib/jev/breaker.js"
fx_new f-unmap-ok
SID="jev2460-f-unmap-ok"
mock_mode '{"systemone":"missing"}'
pre_n "$SID" a 2
mock_mode '{}'
pre_n "$SID" b 1
check "unmappable, unmappable, ok: the ok answer resets the count to 0" "0" "$(breaker_field "$SID" consecutive_failures)"
case_end

echo "=== tryAcquire: closed, open and half-open (injected clock) ==="
HPROBE="$(np "$LIBDIR/hardening-probe.js")"
# kp <cmd> [args...]: one hardening-probe process in the current fixture, away from the worktree.
kp() {
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
      bash "$RWT" 60 node "$HPROBE" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null
  )
}
# seed_breaker <sid> <failures> <open_until_ms>: write breaker.json; BSTATE holds its exact text.
seed_breaker() {
  mkdir -p "$JEVDIR/$1"
  BSTATE="{\"consecutive_failures\":$2,\"open_until_ms\":$3,\"last_failure_status\":\"timeout\"}"
  printf '%s' "$BSTATE" > "$JEVDIR/$1/breaker.json"
}
bexpr() { hq json-expr "$(np "$JEVDIR/$1/breaker.json")" "$2"; }
T0=1700000000000
case_begin "f-try-acquire-table" "hooks/lib/jev/breaker.js"
fx_new f-acq
check "fixture: threshold|OPEN_MS|TRIAL_MS" "3|600000|30000" "$(kp consts)"
check "no breaker.json: true, and nothing is written" "true|absent" "$(kp acquire jev2460-f-acq-none "$T0")"
seed_breaker jev2460-f-acq-closed 2 0
check "2 failures, not open: true, breaker.json byte-identical" "true|$BSTATE" "$(kp acquire jev2460-f-acq-closed "$T0")"
seed_breaker jev2460-f-acq-open 3 $((T0 + 1000))
check "open (open_until_ms > now): false, breaker.json byte-identical" "false|$BSTATE" "$(kp acquire jev2460-f-acq-open "$T0")"
seed_breaker jev2460-f-acq-below 1 $((T0 + 1000))
check "below threshold but open_until_ms ahead: false, unchanged" "false|$BSTATE" "$(kp acquire jev2460-f-acq-below "$T0")"
case_end

case_begin "f-try-acquire-half-open-single-trial" "hooks/lib/jev/breaker.js"
fx_new f-trial
SID="jev2460-f-trial"
seed_breaker "$SID" 3 "$T0"
check "open_until_ms == now (expired at the boundary): the first caller gets the trial" "true" \
  "$(kp acquire "$SID" "$T0" | cut -d'|' -f1)"
check "the trial re-opens for exactly TRIAL_MS; the failure count is kept" "$((T0 + 30000))|3" \
  "$(bexpr "$SID" 'o && o.open_until_ms + "|" + o.consecutive_failures')"
check "an immediate second caller is refused" "false" "$(kp acquire "$SID" $((T0 + 1)) | cut -d'|' -f1)"
check "a trial that never reported back expires: the next caller gets a new trial" "true|$((T0 + 60000))" \
  "$(kp acquire "$SID" $((T0 + 30000)) | cut -d'|' -f1)|$(bexpr "$SID" 'o && o.open_until_ms')"
kp succeed "$SID" > /dev/null
check "the trial's success resets the breaker to closed" "0|0" "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
check "closed again: true" "true" "$(kp acquire "$SID" $((T0 + 30001)) | cut -d'|' -f1)"
case_end

case_begin "f-try-acquire-trial-failure-reopens" "hooks/lib/jev/breaker.js"
fx_new f-trial-fail
SID="jev2460-f-trial-fail"
seed_breaker "$SID" 3 $((T0 - 1))
check "fixture: half-open, the trial is granted" "true" "$(kp acquire "$SID" "$T0" | cut -d'|' -f1)"
kp fail "$SID" timeout $((T0 + 5)) > /dev/null
check "the trial's failure re-opens for OPEN_MS from the failure, count 4" "$((T0 + 5 + 600000))|4" \
  "$(bexpr "$SID" 'o && o.open_until_ms + "|" + o.consecutive_failures')"
check "one ms before the re-open expires: refused" "false" "$(kp acquire "$SID" $((T0 + 600004)) | cut -d'|' -f1)"
check "at the re-open expiry: a new trial" "true" "$(kp acquire "$SID" $((T0 + 600005)) | cut -d'|' -f1)"
case_end

case_begin "f-try-acquire-lock-error-fails-open" "hooks/lib/jev/breaker.js"
fx_new f-lockfail
seed_breaker jev2460-f-lf-open 3 $((T0 + 1000))
check "lock throws while open: false (never a throw), state unchanged" "false|$BSTATE" "$(kp acquire-lockfail jev2460-f-lf-open "$T0")"
seed_breaker jev2460-f-lf-half 3 $((T0 - 1))
check "lock throws while half-open: true, state unchanged" "true|$BSTATE" "$(kp acquire-lockfail jev2460-f-lf-half "$T0")"
case_end

echo "=== half-open under concurrency: exactly one trial ==="
case_begin "f-try-acquire-concurrent-half-open" "hooks/lib/jev/breaker.js"
fx_new f-race
SID="jev2460-f-race"
NOW_MS="$(hq now)"
seed_breaker "$SID" 3 $((NOW_MS - 1000))
AT=$((NOW_MS + 6000))
RACE_PIDS=()
for i in 1 2 3 4; do
  kp race "$SID" "$AT" > "$FX/io/race-$i.txt" &
  RACE_PIDS+=($!)
done
wait "${RACE_PIDS[@]}"
RACE_ALL="$(cat "$FX/io/race-1.txt" "$FX/io/race-2.txt" "$FX/io/race-3.txt" "$FX/io/race-4.txt" | tr -d '\n')"
check "fixture: all four racers answered true or false" "true" \
  "$([[ "$RACE_ALL" =~ ^((true|false)){4}$ ]] && echo true || echo "false: $RACE_ALL")"
check "exactly one of four concurrent callers gets the trial" "1|3" \
  "$(grep -o true <<< "$RACE_ALL" | wc -l | tr -d ' ')|$(grep -o false <<< "$RACE_ALL" | wc -l | tr -d ' ')"
check "the trial window starts at the shared start and lasts TRIAL_MS; count kept; no lock left" "true|3|absent" \
  "$(bexpr "$SID" "o && o.open_until_ms >= $AT + 30000 && o.open_until_ms <= now + 30000")|$(breaker_field "$SID" consecutive_failures)|$([ -e "$JEVDIR/$SID/breaker.json.lock" ] && echo present || echo absent)"
case_end

echo "=== a late success cannot clear a breaker that opened or started a trial after admission ==="
case_begin "f-late-success-keeps-later-open" "hooks/lib/jev/breaker.js"
fx_new f-late-open
SID="jev2460-f-late-open"
check "fixture: admitted at T0 while closed" "true" "$(kp acquire "$SID" "$T0" | cut -d'|' -f1)"
for _i in 1 2 3; do kp fail "$SID" timeout $((T0 + 10)) > /dev/null; done
check "fixture: three failures after admission opened the breaker" "3|$((T0 + 600010))" \
  "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
kp succeed "$SID" "$T0" > /dev/null
check "a success admitted at T0 leaves the later-opened breaker open, count 3" "3|$((T0 + 600010))|false" \
  "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')|$(kp acquire "$SID" $((T0 + 20)) | cut -d'|' -f1)"
case_end
case_begin "f-late-success-keeps-later-trial" "hooks/lib/jev/breaker.js"
fx_new f-late-trial
SID="jev2460-f-late-trial"
T2=$((T0 + 700000))
seed_breaker "$SID" 3 $((T2 - 1))
check "half-open at T2: the trial is granted" "true" "$(kp acquire "$SID" "$T2" | cut -d'|' -f1)"
check "the trial records trial_at_ms = T2 beside open_until_ms = T2 + TRIAL_MS" "$((T2 + 30000))|$T2" \
  "$(bexpr "$SID" 'o && o.open_until_ms + "|" + String(o.trial_at_ms)')"
kp succeed "$SID" "$T0" > /dev/null
check "a stale success admitted at T0 < T2 does not clear the trial: a second caller is still refused" "false|3" \
  "$(kp acquire "$SID" $((T2 + 1)) | cut -d'|' -f1)|$(breaker_field "$SID" consecutive_failures)"
kp succeed "$SID" "$T2" > /dev/null
check "the trial's own success (admittedAtMs = T2) resets the breaker" "0|0" \
  "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
case_end
case_begin "f-success-without-opts-resets-unconditionally" "hooks/lib/jev/breaker.js"
fx_new f-succ-noopts
SID="jev2460-f-succ-noopts"
seed_breaker "$SID" 3 $((T0 + 1000))
kp succeed "$SID" > /dev/null
check "recordSuccess(sid) with no opts resets an open breaker" "0|0" \
  "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
case_end
case_begin "f-success-admitted-while-closed-resets" "hooks/lib/jev/breaker.js"
fx_new f-succ-closed
SID="jev2460-f-succ-closed"
kp fail "$SID" timeout "$T0" > /dev/null
kp fail "$SID" timeout "$T0" > /dev/null
check "fixture: two failures, still closed" "2|0" "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
kp succeed "$SID" "$T0" > /dev/null
check "a success admitted while closed resets the count" "0|0" \
  "$(bexpr "$SID" 'o && o.consecutive_failures + "|" + o.open_until_ms')"
case_end
case_begin "f-broker-late-success-keeps-open-breaker" "hooks/lib/jev/broker.js"
# Through the real pre hook: runJev must pass its admission time to recordSuccess.
fx_new f-broker-late
SID="jev2460-f-broker-late"
mock_mode '{"systemone":"slow","delayMs":4000}'
mkpayload "$FX/io/pre-late.json" pre "$SID" toolu_f_broker_late
run_hook pre "$FX/io/pre-late.json" JEV_HTTP_TIMEOUT_MS=12000 &
LATE_PID=$!
# The mock logs a request before its delayed answer, so a logged POST means admitted and in flight.
_w=0
until grep -qF '"path":"/v1/systemone"' "$MOCK_REQ" 2>/dev/null || [[ "$_w" -ge 300 ]]; do sleep 0.05; _w=$((_w + 1)); done
check "fixture: the query is in flight and no breaker.json existed at admission" "1|absent" \
  "$(grep -cF '"path":"/v1/systemone"' "$MOCK_REQ")|$([[ -e "$JEVDIR/$SID/breaker.json" ]] && echo present || echo absent)"
LATE_OPEN=$(( $(hq now) + 600000 ))
LATE_STATE="{\"consecutive_failures\":3,\"open_until_ms\":$LATE_OPEN,\"trial_at_ms\":0,\"last_failure_status\":\"timeout\"}"
mkdir -p "$JEVDIR/$SID"
printf '%s' "$LATE_STATE" > "$JEVDIR/$SID/breaker.json.tmp"
mv -f "$JEVDIR/$SID/breaker.json.tmp" "$JEVDIR/$SID/breaker.json"
wait "$LATE_PID"
check "the in-flight query finished ok (the success path ran)" "ok|1" \
  "$(hq json-expr "$(np "$JEVDIR/$SID/pending/toolu_f_broker_late.json")" 'o && o.jev.status')|$(mock_count systemone)"
check "the late success left the breaker opened during the query byte-identical" "$LATE_STATE" \
  "$(cat "$JEVDIR/$SID/breaker.json" 2>/dev/null)"
check "the breaker is still open with count 3" "3|true" \
  "$(breaker_field "$SID" consecutive_failures)|$(bexpr "$SID" 'o && o.open_until_ms > now')"
case_end

echo "=== liveness probe ==="
case_begin "f-probe-http-error-keeps-status" "hooks/lib/jev/liveness.js"
fx_new f-probe500
SID="jev2460-f-probe500"
mock_mode '{"models":"http:500"}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_f_probe500
check "/v1/models 500: no systemone query" "0|1" "$(mock_count systemone)|$(mock_count models)"
check "/v1/models 500: recorded as http-error with http_status 500" "http-error|500|http-error" \
  "$(rq toolu_f_probe500 'r && [r.jev.status, r.jev.http_status, r.fallback_reason].join("|")')"
check "/v1/models 500: breaker last_failure_status is http-error" '"http-error"' "$(breaker_field "$SID" last_failure_status)"
check "/v1/models 500: counted once by the breaker; failure not cached" "1|absent" \
  "$(breaker_field "$SID" consecutive_failures)|$([ -e "$JEVDIR/$SID/liveness.json" ] && echo present || echo absent)"
case_end
case_begin "f-probe-timeout-keeps-status" "hooks/lib/jev/liveness.js"
fx_new f-probeslow
SID="jev2460-f-probeslow"
mock_mode '{"models":"slow","delayMs":4000}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_f_probeslow JEV_HTTP_TIMEOUT_MS=500
check "slow /v1/models: no systemone query" "0" "$(mock_count systemone)"
check "slow /v1/models: recorded as timeout with http_status null" "timeout|null|timeout" \
  "$(rq toolu_f_probeslow 'r && [r.jev.status, String(r.jev.http_status), r.fallback_reason].join("|")')"
check "slow /v1/models: breaker counts one failure, last status timeout" '1|"timeout"' \
  "$(breaker_field "$SID" consecutive_failures)|$(breaker_field "$SID" last_failure_status)"
case_end
case_begin "f-probe-401-bad-key-is-http-error" "hooks/lib/jev/provider-core.js"
fx_new f-probe401
SID="jev2460-f-probe401"
mock_mode '{"models":"http:401"}'
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_f_probe401
check "/v1/models 401: no systemone query" "0|1" "$(mock_count systemone)|$(mock_count models)"
check "/v1/models 401: http-error, http_status 401, fallback_reason http-error" "http-error|401|http-error" \
  "$(rq toolu_f_probe401 'r && [r.jev.status, r.jev.http_status, r.fallback_reason].join("|")')"
check "/v1/models 401: breaker counts one http-error failure" '1|"http-error"' \
  "$(breaker_field "$SID" consecutive_failures)|$(breaker_field "$SID" last_failure_status)"
case_end
case_begin "f-probe-connection-refused-is-unreachable" "hooks/lib/jev/provider-core.js"
fx_new f-probe-refused
SID="jev2460-f-probe-refused"
# A loopback port bound then released: nothing listens, so the connect is refused.
CLOSED_PORT="$(run_with_timeout 30 node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => process.stdout.write(String(p))); });' 2>/dev/null)"
check "fixture: a released loopback port number was obtained" "true" \
  "$([[ "$CLOSED_PORT" =~ ^[0-9]+$ ]] && echo true || echo "false:$CLOSED_PORT")"
# A generous timeout keeps Windows' slow refused-connect retry from reading as a timeout.
LLM_TEXT="SIGNALS: S1-multi-file" pair "$SID" toolu_f_probe_refused \
  "JEV_BASE_URL=http://127.0.0.1:$CLOSED_PORT" JEV_HTTP_TIMEOUT_MS=10000
check "refused /v1/models: unreachable, http_status null, fallback_reason unreachable" "unreachable|null|unreachable" \
  "$(rq toolu_f_probe_refused 'r && [r.jev.status, String(r.jev.http_status), r.fallback_reason].join("|")')"
check "refused /v1/models: breaker counts one unreachable failure" '1|"unreachable"' \
  "$(breaker_field "$SID" consecutive_failures)|$(breaker_field "$SID" last_failure_status)"
case_end
case_begin "f-probe-cached-within-ttl" "hooks/lib/jev/liveness.js"
fx_new f-cache
SID="jev2460-f-cache"
mock_mode '{}'
pre_n "$SID" cache 2
check "two dispatches within 10 minutes probe once, query twice" "1|2" \
  "$(mock_count models)|$(mock_count systemone)"
check "liveness.json holds a numeric checked_at_ms" "number" \
  "$(hq json-expr "$(np "$JEVDIR/$SID/liveness.json")" 'o && typeof o.checked_at_ms')"
hq json-set "$(np "$JEVDIR/$SID/liveness.json")" checked_at_ms "$(( $(hq now) - 660000 ))"
pre_n "$SID" cache-stale 1
check "checked_at_ms 11 minutes old: the next dispatch probes again" "2" "$(mock_count models)"
case_end
case_begin "f-no-probe-while-open" "hooks/lib/jev/liveness.js"
fx_new f-openprobe
SID="jev2460-f-openprobe"
mock_mode '{"models":"http:500"}'
pre_n "$SID" p 3
check "fixture: three probe failures opened the breaker (non-vacuity)" "3|3" \
  "$(mock_count models)|$(breaker_field "$SID" consecutive_failures)"
mock_mode '{}'
pre_n "$SID" q 1
check "while the breaker is open neither the probe nor the query is sent" "0|0" \
  "$(mock_count models)|$(mock_count systemone)"
case_end

finish
