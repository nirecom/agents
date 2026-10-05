#!/usr/bin/env bash
# Tests: hooks/lib/jev/provider-core.js, hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js
# Tags: TL2, hooks, jev, provider, http-errors, secrets, untrusted-response, redirect, response-cap, scope:issue-specific, pwsh-not-required, failure-shape, closed-port, midbody-stall, artifact-session-fallback

# The provider classifies every Jev outcome into one enum status and keeps untrusted
# response content out of the log, stderr and the hooks' stdout: error bodies are dropped
# unread, the model name is charset/length-capped, usage must be a sane integer, and the
# API key rides only in the Authorization header. Driven end to end through the hooks.

# TL3 gap (what this test does NOT catch): the real api.typesafe.ai response shape and
# latency; the live verification in the detail plan (S14) covers one real call.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start
SID="jev2460-c-sid"
# A loopback URL whose port was just bound and released, so a connect is really refused
# (fetch rejects port 1 as a blocked port before it ever connects).
CLOSED_URL="$(run_with_timeout 30 node -e '
  const s = require("net").createServer();
  s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => process.stdout.write("http://127.0.0.1:" + p)); });
' 2>/dev/null)"
# refused_code <url>: a plain client's connect error code for <url> (OK when it connected).
refused_code() {
  run_with_timeout 30 node -e '
    fetch(process.argv[1] + "/v1/models").then(() => process.stdout.write("OK"))
      .catch((e) => process.stdout.write(String((e && e.cause && e.cause.code) || (e && e.message))));
  ' "$1" 2>/dev/null
}

# run_mode <tag> <mode-json> [VAR=value ...]: fresh fixture, one pre+post pair, tid toolu_c_<tag>.
run_mode() {
  local tag="$1" mode="$2"
  shift 2
  fx_new "c-$tag"
  mock_mode "$mode"
  pair "$SID" "toolu_c_$tag" "$@"
  TID="toolu_c_$tag"
}

echo "=== ok response ==="
case_begin "c-ok-answer-usage-auth" "hooks/lib/jev/provider-core.js"
run_mode ok '{}'
check "ok: status, answer, model, input_tokens" "ok|S1-multi-file|jev-1.13.0|296" \
  "$(rq "$TID" 'r && [r.jev.status, r.jev.answer, r.jev.model, r.jev.input_tokens].join("|")')"
check "ok: est_cost_usd = input_tokens x 0.042 / 1e6" "true" \
  "$(rq "$TID" 'r && Math.abs(r.jev.est_cost_usd - 296 * 0.042 / 1e6) < 1e-12')"
check "ok: http_status is null and fallback_reason is null" "null|null" \
  "$(rq "$TID" 'r && [String(r.jev.http_status), String(r.fallback_reason)].join("|")')"
check "ok: one POST /v1/systemone carrying Bearer <sentinel key>" "1|true" \
  "$(hq mock-q "$(np "$MOCK_REQ")" 'reqs.filter(q => q.path === "/v1/systemone" && q.method === "POST").length + "|" + reqs.filter(q => q.path === "/v1/systemone").every(q => q.bearer_sentinel)')"
check "ok: both hooks exit 0" "0|0" "$PRE_RC|$HOOK_RC"
case_end

echo "=== HTTP errors keep only the numeric status ==="
http_rows() {
  local code="$1"
  run_mode "h$code" "{\"systemone\":\"http:$code\"}"
  check "HTTP $code: status http-error, http_status $code, fallback_reason http-error" \
    "http-error|$code|http-error" \
    "$(rq "$TID" 'r && [r.jev.status, r.jev.http_status, r.fallback_reason].join("|")')"
  check "HTTP $code: hooks still exit 0" "0|0" "$PRE_RC|$HOOK_RC"
}
case_begin "c-http-401" "hooks/lib/jev/provider-core.js"
http_rows 401
case_end
case_begin "c-http-422" "hooks/lib/jev/provider-core.js"
http_rows 422
case_end
case_begin "c-http-429" "hooks/lib/jev/provider-core.js"
http_rows 429
case_end
case_begin "c-http-529" "hooks/lib/jev/provider-core.js"
http_rows 529
case_end
case_begin "c-http-500" "hooks/lib/jev/provider-core.js"
http_rows 500
case_end

echo "=== transport and body failures ==="
case_begin "c-timeout" "hooks/lib/jev/provider-core.js"
run_mode timeout '{"systemone":"slow","delayMs":4000}' JEV_HTTP_TIMEOUT_MS=500
check "slow systemone past JEV_HTTP_TIMEOUT_MS: status timeout" "timeout" "$(rq "$TID" 'r && r.jev.status')"
case_end
case_begin "c-unreachable" "hooks/lib/jev/provider-core.js"
check "fixture: the closed ephemeral port refuses a real connect (non-vacuity)" "true|ECONNREFUSED" \
  "$([[ "$CLOSED_URL" =~ ^http://127\.0\.0\.1:[0-9]{2,5}$ ]] && echo true || echo false)|$(refused_code "$CLOSED_URL")"
run_mode unreachable '{}' "JEV_BASE_URL=$CLOSED_URL"
check "nothing listening on the base URL: status unreachable" "unreachable" "$(rq "$TID" 'r && r.jev.status')"
case_end
case_begin "c-bad-json" "hooks/lib/jev/provider-core.js"
run_mode badjson '{"systemone":"badjson"}'
check "truncated JSON body: status bad-response" "bad-response" "$(rq "$TID" 'r && r.jev.status')"
case_end

echo "=== redirects are refused: the body and the key never follow one ==="
# run_split <tag> <mode-json> [VAR=value ...]: run_mode that also keeps the pre hook's own stdout.
run_split() {
  local tag="$1" mode="$2"
  shift 2
  fx_new "c-$tag"
  mock_mode "$mode"
  TID="toolu_c_$tag"
  mkpayload "$FX/io/pre-$TID.json" pre "$SID" "$TID"
  mkpayload "$FX/io/post-$TID.json" post "$SID" "$TID"
  run_hook pre "$FX/io/pre-$TID.json" "$@"
  PRE_RC=$HOOK_RC; PRE_OUT="$(cat "$OUT")"
  run_hook post "$FX/io/post-$TID.json" "$@"
}
breaker_state() { echo "$(hq json-get "$(np "$JEVDIR/$SID/breaker.json")" consecutive_failures)|$(hq json-get "$(np "$JEVDIR/$SID/breaker.json")" last_failure_status)"; }
# core_call <probe|run>: the provider's own return value, then the calling process's exit code.
core_call() {
  run_with_timeout 30 node -e '
    const p = require(process.argv[1]);
    const { captureTestOverrides } = require(process.argv[2]);
    const ctx = p.jevCoreInit({ sessionId: "s", overrides: captureTestOverrides({ JEV_BASE_URL: process.argv[3] }) });
    ctx.apiKey = process.argv[4];
    const show = (r) => process.stdout.write(process.argv[5] === "probe" ? JSON.stringify(r)
      : [r.status, String(r.http_status), r.response ? Object.keys(r.response.answers).length : "none"].join("|"));
    (process.argv[5] === "probe" ? p.jevCoreProbe(ctx) : p.jevCoreRun(ctx, { state: "STATE-2460", questions: {} })).then(show);
  ' "$PROVIDER_JS" "$OVERRIDES_JS" "$MOCK_URL" "$SENTINEL_KEY" "$1" 2>/dev/null < /dev/null
  echo "|rc=$?"
}
# mock_fetch <follow|manual>: a plain client's view of POST /v1/systemone: status|content-length|body bytes.
mock_fetch() {
  run_with_timeout 30 node -e '
    fetch(process.argv[1] + "/v1/systemone", { method: "POST", body: "{}", redirect: process.argv[2] })
      .then(async (r) => process.stdout.write([r.status, String(r.headers.get("content-length")), (await r.arrayBuffer()).byteLength].join("|")))
      .catch(() => process.stdout.write("FETCH-ERROR"));
  ' "$MOCK_URL" "$1" 2>/dev/null
}

case_begin "c-redirect-not-followed" "hooks/lib/jev/provider-core.js"
mock_mode '{"systemone":"redirect:307"}'
check "fixture: a redirect-following client gets the sink's 200 and the sink counts it (non-vacuity)" "200|1" \
  "$(mock_fetch follow | cut -d'|' -f1)|$(sink_total)"
for code in 301 302 303 307 308; do
  mock_mode "{\"systemone\":\"redirect:$code\"}"
  check "jevCoreRun on $code: unreachable, http_status null, process exits 0" "unreachable|null|none|rc=0" "$(core_call run)"
  check "$code: the request reached the mock with the key; nothing reached the redirect target" "1|true|0" \
    "$(mock_count systemone)|$(hq mock-q "$(np "$MOCK_REQ")" 'reqs.every(q => q.bearer_sentinel)')|$(sink_total)"
done
case_end
case_begin "c-redirect-probe-not-followed" "hooks/lib/jev/provider-core.js"
for code in 302 307; do
  mock_mode "{\"models\":\"redirect:$code\"}"
  check "jevCoreProbe on $code: {ok:false,status:unreachable}, process exits 0" '{"ok":false,"status":"unreachable"}|rc=0' "$(core_call probe)"
  check "$code: one probe sent, nothing reached the redirect target" "1|0" "$(mock_count models)|$(sink_total)"
done
case_end
case_begin "c-redirect-hook-fail-open" "hooks/jev-shadow-pre.js"
run_split redir307 '{"systemone":"redirect:307"}'
check "307 on systemone: recorded unreachable, http_status null, fallback_reason unreachable" "unreachable|null|unreachable" \
  "$(rq "$TID" 'r && [r.jev.status, String(r.jev.http_status), r.fallback_reason].join("|")')"
check "307 on systemone: both hooks exit 0, the pre hook prints nothing" "0|0|" "$PRE_RC|$HOOK_RC|$PRE_OUT"
check "307 on systemone: one query sent, the redirect target saw nothing, the breaker counts one outage" \
  "1|0|1|\"unreachable\"" "$(mock_count systemone)|$(sink_total)|$(breaker_state)"
run_split redirprobe '{"models":"redirect:302"}'
check "302 on the probe: recorded unreachable, no query, the redirect target saw nothing, one outage counted" \
  "unreachable|0|0|1|\"unreachable\"" "$(rq "$TID" 'r && r.jev.status')|$(mock_count systemone)|$(sink_total)|$(breaker_state)"
check "302 on the probe: both hooks exit 0, the pre hook prints nothing" "0|0|" "$PRE_RC|$HOOK_RC|$PRE_OUT"
case_end

echo "=== a success body is read up to 64 KiB and no further ==="
case_begin "c-response-cap-boundary" "hooks/lib/jev/provider-core.js"
check "MAX_RESPONSE_BYTES is exported as 65536" "65536" \
  "$(run_with_timeout 30 node -e 'process.stdout.write(String(require(process.argv[1]).MAX_RESPONSE_BYTES))' "$PROVIDER_JS" 2>/dev/null)"
mock_mode '{"systemone":"sized:65537"}'
check "fixture: sized:65537 is a 200 declaring and carrying 65537 bytes" "200|65537|65537" "$(mock_fetch manual)"
mock_mode '{"systemone":"chunked:65537"}'
check "fixture: chunked:65537 is a 200 carrying 65537 bytes with no content-length" "200|null|65537" "$(mock_fetch manual)"
while read -r mode want; do
  mock_mode "{\"systemone\":\"$mode\"}"
  check "jevCoreRun on $mode: $want, process exits 0" "$want|rc=0" "$(core_call run)"
done <<'ROWS'
sized:1024 ok|null|7
sized:65535 ok|null|7
sized:65536 ok|null|7
sized:65537 bad-response|null|none
sized:1048576 bad-response|null|none
chunked:65535 ok|null|7
chunked:65536 ok|null|7
chunked:65537 bad-response|null|none
chunked:1048576 bad-response|null|none
ROWS
case_end
case_begin "c-response-cap-hook-fail-open" "hooks/jev-shadow-pre.js"
run_split capchunk '{"systemone":"chunked:1048576"}'
check "1 MiB chunked body: recorded bad-response, http_status null, fallback_reason bad-response" "bad-response|null|bad-response" \
  "$(rq "$TID" 'r && [r.jev.status, String(r.jev.http_status), r.fallback_reason].join("|")')"
check "1 MiB chunked body: both hooks exit 0 (no crash on the cancelled stream), the pre hook prints nothing" "0|0|" \
  "$PRE_RC|$HOOK_RC|$PRE_OUT"
check "1 MiB chunked body: the breaker counts one bad-response outage" "1|\"bad-response\"" "$(breaker_state)"
run_split capsized '{"systemone":"sized:65537"}'
check "content-length 65537: recorded bad-response, both hooks exit 0, the pre hook prints nothing, one outage" \
  "bad-response|0|0||1|\"bad-response\"" "$(rq "$TID" 'r && r.jev.status')|$PRE_RC|$HOOK_RC|$PRE_OUT|$(breaker_state)"
run_split capok '{"systemone":"chunked:65536"}'
check "exactly 65536 bytes: recorded ok with the answer, no outage counted" "ok|S1-multi-file|0" \
  "$(rq "$TID" 'r && [r.jev.status, r.jev.answer].join("|")')|$(hq json-get "$(np "$JEVDIR/$SID/breaker.json")" consecutive_failures)"
case_end

echo "=== error bodies never surface ==="
case_begin "c-error-body-dropped" "hooks/jev-shadow-post.js"
run_mode errbody '{"systemone":"http500-sentinel"}'
check "sentinel error body: status http-error/500" "http-error|500" \
  "$(rq "$TID" 'r && [r.jev.status, r.jev.http_status].join("|")')"
check "sentinel error body absent from log, stderr and post-hook stdout" "absent|absent|absent" \
  "$(grep_absent "$ERRBODY_SENTINEL" "$FX/state")|$(grep_absent "$ERRBODY_SENTINEL" "$ERR_ALL")|$(grep_absent "$ERRBODY_SENTINEL" "$OUT")"
case_end

echo "=== untrusted model name and usage are sanitised ==="
case_begin "c-model-control-chars" "hooks/lib/jev/provider-core.js"
run_mode modelctrl '{"systemone":"badmodel-ctrl"}'
check "model with control chars becomes unknown" "unknown" "$(rq "$TID" 'r && r.jev.model')"
check "the injected model text never reaches the log or the post hook's stdout" "absent|absent" \
  "$(grep_absent 'SIGNALS: S3-security' "$FX/state")|$(grep_absent 'SIGNALS: S3-security' "$OUT")"
case_end
case_begin "c-model-too-long" "hooks/lib/jev/provider-core.js"
run_mode modellong '{"systemone":"badmodel-long"}'
check "200-char model name becomes unknown" "unknown" "$(rq "$TID" 'r && r.jev.model')"
case_end
case_begin "c-usage-negative" "hooks/lib/jev/provider-core.js"
run_mode badusage '{"systemone":"badusage"}'
check "negative usage.input_tokens is recorded as null" "null" "$(rq "$TID" 'r && String(r.jev.input_tokens)')"
case_end

echo "=== no key: nothing is sent ==="
case_begin "c-no-key-no-request" "hooks/lib/jev/provider-core.js"
run_mode nokey '{}' TYPESAFE_API_KEY=__unset__
check "no key: zero requests of any kind" "0" "$(mock_total)"
check "no key: status no-key, fallback_reason no-key" "no-key|no-key" \
  "$(rq "$TID" 'r && [r.jev.status, r.fallback_reason].join("|")')"
case_end

echo "=== the key never leaks ==="
case_begin "c-sentinel-key-never-logged" "hooks/jev-shadow-post.js"
LEAK="absent"
for tag in ok h401 h500 timeout unreachable badjson redir307 redirprobe capchunk capsized errbody modelctrl; do
  d="$TMPROOT/fx-c-$tag"
  [ "$(grep_absent "$SENTINEL_KEY" "$d/state" "$d/io/out.txt" "$d/io/err-all.txt")" = absent ] || LEAK="present in $tag"
done
check "the sentinel key is absent from every log, stdout and stderr above" "absent" "$LEAK"
case_end

echo "=== failure returns carry only status, http_status and latency_ms ==="
# core_both <base-url> <timeout-ms|""> <expr>: probe then run on fresh contexts; <expr> sees
# pr (probe result) and r (run result). Prints THREW when either call rejects.
core_both() {
  run_with_timeout 30 node -e '
    const pc = require(process.argv[1]);
    const { captureTestOverrides } = require(process.argv[2]);
    const mk = () => {
      const c = pc.jevCoreInit({ sessionId: "s", overrides: captureTestOverrides({ JEV_BASE_URL: process.argv[3], JEV_HTTP_TIMEOUT_MS: process.argv[4] }) });
      c.apiKey = process.argv[5];
      return c;
    };
    (async () => {
      const pr = await pc.jevCoreProbe(mk());
      const r = await pc.jevCoreRun(mk(), { state: "STATE-2460", questions: {} });
      process.stdout.write(String(eval(process.argv[6])));
    })().catch(() => process.stdout.write("THREW"));
  ' "$PROVIDER_JS" "$OVERRIDES_JS" "$1" "$2" "$SENTINEL_KEY" "$3" 2>/dev/null < /dev/null
}
RUN_KEYS='Object.keys(r).sort().join(",")'

case_begin "c-run-failure-http-401-shape" "hooks/lib/jev/provider-core.js"
mock_mode '{"systemone":"http:401"}'
check "jevCoreRun on 401: http-error, integer 401, latency_ms a finite number >= 0, exactly three keys (no error)" \
  "http-error|401|true|true|http_status,latency_ms,status" \
  "$(core_both "$MOCK_URL" "" "[r.status, r.http_status, Number.isInteger(r.http_status), typeof r.latency_ms === 'number' && Number.isFinite(r.latency_ms) && r.latency_ms >= 0, $RUN_KEYS].join('|')")"
case_end

case_begin "c-run-failure-midbody-destroy-shape" "hooks/lib/jev/provider-core.js"
mock_mode '{"systemone":"destroy-midbody"}'
check "fixture: destroy-midbody answers 200 and then breaks the body read (non-vacuity)" "200|body-error" \
  "$(run_with_timeout 30 node -e '
    fetch(process.argv[1] + "/v1/systemone", { method: "POST", body: "{}" })
      .then(async (r) => { let b = "body-ok"; try { await r.arrayBuffer(); } catch (_e) { b = "body-error"; } process.stdout.write(r.status + "|" + b); })
      .catch(() => process.stdout.write("FETCH-ERROR"));
  ' "$MOCK_URL" 2>/dev/null)"
mock_mode '{"systemone":"destroy-midbody"}'
# The socket dies at ~100 ms, far inside the default 6 s query timeout, so no abort has fired.
check "jevCoreRun on a socket torn down mid-body with no abort: unreachable, http_status null, latency_ms a finite number >= 0, exactly three keys (no error)" \
  "unreachable|true|true|http_status,latency_ms,status" \
  "$(core_both "$MOCK_URL" "" "[r.status, r.http_status === null, typeof r.latency_ms === 'number' && Number.isFinite(r.latency_ms) && r.latency_ms >= 0, $RUN_KEYS].join('|')")"
check "the serialised result carries no Error name, message or stack text" "false" \
  "$(core_both "$MOCK_URL" "" "new RegExp('Error|stack| at |socket|terminated|other side closed', 'i').test(JSON.stringify(r))")"
case_end

case_begin "c-run-failure-midbody-stall-timeout" "hooks/lib/jev/provider-core.js"
mock_mode '{"systemone":"stall-midbody","delayMs":5000}'
check "fixture: stall-midbody answers 200 and then never finishes the body within 1 s (non-vacuity)" "200|body-stalled" \
  "$(run_with_timeout 30 node -e '
    fetch(process.argv[1] + "/v1/systemone", { method: "POST", body: "{}", signal: AbortSignal.timeout(1000) })
      .then(async (r) => { let b = "body-ok"; try { await r.arrayBuffer(); } catch (_e) { b = "body-stalled"; } process.stdout.write(r.status + "|" + b); })
      .catch(() => process.stdout.write("FETCH-ERROR"));
  ' "$MOCK_URL" 2>/dev/null)"
mock_mode '{"systemone":"stall-midbody","delayMs":5000}'
check "jevCoreRun on a body stalled past the 500 ms timeout: timeout, http_status null, waited for the timer, exactly three keys (no error)" \
  "timeout|true|true|http_status,latency_ms,status" \
  "$(core_both "$MOCK_URL" 500 "[r.status, r.http_status === null, typeof r.latency_ms === 'number' && Number.isFinite(r.latency_ms) && r.latency_ms >= 400, $RUN_KEYS].join('|')")"
case_end

case_begin "c-run-failure-unreachable-shape" "hooks/lib/jev/provider-core.js"
check "fixture: the closed ephemeral port refuses a real connect (non-vacuity)" "ECONNREFUSED" "$(refused_code "$CLOSED_URL")"
check "jevCoreRun on a closed port: {status:unreachable, http_status:null}, latency_ms a finite number >= 0, no error key" \
  "unreachable|true|true|http_status,latency_ms,status" \
  "$(core_both "$CLOSED_URL" "" "[r.status, r.http_status === null, typeof r.latency_ms === 'number' && Number.isFinite(r.latency_ms) && r.latency_ms >= 0, $RUN_KEYS].join('|')")"
check "jevCoreProbe on a closed port: exactly {ok:false, status:unreachable}" '{"ok":false,"status":"unreachable"}' \
  "$(core_both "$CLOSED_URL" "" "JSON.stringify(pr)")"
case_end

case_begin "c-probe-run-failure-symmetry" "hooks/lib/jev/provider-core.js"
# Same failure on both routes: probe and run report the same status and the same http code
# (the probe omits http_status unless it is an integer); neither carries an error key.
SYM='[pr.status === r.status, (pr.http_status === undefined ? null : pr.http_status) === r.http_status, !("error" in pr) && !("error" in r), pr.status].join("|")'
mock_mode '{"systemone":"http:401","models":"http:401"}'
check "401 on both routes: same status and code" "true|true|true|http-error" "$(core_both "$MOCK_URL" "" "$SYM")"
mock_mode '{"systemone":"redirect:307","models":"redirect:307"}'
check "307 on both routes: same status" "true|true|true|unreachable" "$(core_both "$MOCK_URL" "" "$SYM")"
mock_mode '{"systemone":"slow","models":"slow","delayMs":4000}'
check "slow on both routes past the timeout: same status" "true|true|true|timeout" "$(core_both "$MOCK_URL" 500 "$SYM")"
check "closed port: same status" "true|true|true|unreachable" "$(core_both "$CLOSED_URL" "" "$SYM")"
case_end

echo "=== request contract: what jevCoreRun puts on the wire ==="
# raw_mode <text>: the mock answers POST /v1/systemone with 200 and <text> verbatim.
raw_mode() {
  mock_mode "$(RAW_TEXT="$1" run_with_timeout 30 node -e 'process.stdout.write(JSON.stringify({ systemone: "raw", rawText: process.env.RAW_TEXT }))' 2>/dev/null)"
}
case_begin "c-run-request-body-contract" "hooks/lib/jev/provider-core.js"
mock_mode '{}'
core_call run >/dev/null
check "fixture: without capture the mock records no headers or body (capture is opt-in)" "1|true" \
  "$(mock_count systemone)|$(hq mock-q "$(np "$MOCK_REQ")" 'reqs.every(q => !("headers" in q) && !("body_text" in q))')"
mock_mode '{"capture":true}'
check "jevCoreRun with a dummy key and one question: status ok" "ok" "$(run_with_timeout 30 node -e '
    const p = require(process.argv[1]);
    const { captureTestOverrides } = require(process.argv[2]);
    const ctx = p.jevCoreInit({ sessionId: "s", overrides: captureTestOverrides({ JEV_BASE_URL: process.argv[3] }) });
    ctx.apiKey = process.argv[4];
    const questions = { s1_multi_file: { type: "noul", question: "Does the change touch many files?" } };
    p.jevCoreRun(ctx, { state: "STATE-2460", questions }).then((r) => process.stdout.write(r.status));
  ' "$PROVIDER_JS" "$OVERRIDES_JS" "$MOCK_URL" "$SENTINEL_KEY" 2>/dev/null < /dev/null)"
REQ_Q="$(np "$MOCK_REQ")"
SYS='const s = reqs.filter(q => q.path === "/v1/systemone"); const q = s[0]; const h = q.headers;'
check "exactly one request, POST /v1/systemone" "1|POST|/v1/systemone" \
  "$(hq mock-q "$REQ_Q" "(() => { $SYS return [s.length, q.method, q.path].join('|'); })()")"
check "headers: content-type and accept are application/json, authorization is Bearer <dummy key>" \
  "application/json|application/json|true" \
  "$(hq mock-q "$REQ_Q" "(() => { $SYS return [h['content-type'], h.accept, h.authorization === 'Bearer $SENTINEL_KEY'].join('|'); })()")"
check "body parses as JSON with exactly the keys model, questions, state" "true|model,questions,state" \
  "$(hq mock-q "$REQ_Q" "(() => { $SYS let b; try { b = JSON.parse(q.body_text); } catch (_e) { return 'unparsable'; } return [b !== null && typeof b === 'object' && !Array.isArray(b), Object.keys(b).sort().join(',')].join('|'); })()")"
check "body values: model jev-latest, state passed through, questions passed through unchanged" \
  "jev-latest|STATE-2460|true" \
  "$(hq mock-q "$REQ_Q" "(() => { $SYS const b = JSON.parse(q.body_text); return [b.model, b.state, JSON.stringify(b.questions) === JSON.stringify({ s1_multi_file: { type: 'noul', question: 'Does the change touch many files?' } })].join('|'); })()")"
check "the dummy key appears in no body byte and in no header other than authorization" "false|0" \
  "$(hq mock-q "$REQ_Q" "(() => { $SYS return [q.body_text.includes('$SENTINEL_KEY'), Object.keys(h).filter(k => k !== 'authorization' && String(h[k]).includes('$SENTINEL_KEY')).length].join('|'); })()")"
case_end

echo "=== model and usage sanitiser boundaries ==="
OKANS='"answers":{"s1_multi_file":{"type":"noul","noul":0.9}}'
M64="$(printf 'm%.0s' $(seq 1 64))"
M65="${M64}m"
case_begin "c-sanitize-model-table" "hooks/lib/jev/provider-core.js"
check "fixture: the 64/65-char model names have those lengths" "64|65" "${#M64}|${#M65}"
while IFS='|' read -r name model want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  raw_mode "{$OKANS,\"model\":$model,\"usage\":{\"input_tokens\":296}}"
  check "model $name: sanitised to [$want]" "ok|$want" "$(core_both "$MOCK_URL" "" "[r.status, r.model].join('|')")"
done <<TABLE
empty          | ""             | unknown
null           | null           | unknown
number         | 42             | unknown
len-1          | "a"            | a
len-64         | "$M64"         | $M64
len-65         | "$M65"         | unknown
allowed-symbols| "jev-1.13_0"   | jev-1.13_0
at-sign        | "jev@1"        | unknown
space          | "jev 1"        | unknown
colon          | "jev:1"        | unknown
trailing-lf    | "jev\n"        | unknown
non-ascii      | "jevé"    | unknown
TABLE
# Shell metacharacters and path separators: each name is built as a JSON literal inside JS
# and read back with read -r, so bash never expands or splits it.
META_MODELS="$(run_with_timeout 30 node -e '
  const names = ["`x`", "$(x)", "a;b", "a|b", "a/b", "a\\b", "../x"];
  process.stdout.write(names.map((n) => JSON.stringify(n)).join("\n"));
' 2>/dev/null)"
META_N=0
while IFS= read -r model; do
  [ -z "$model" ] && continue
  META_N=$((META_N + 1))
  raw_mode "{$OKANS,\"model\":$model,\"usage\":{\"input_tokens\":296}}"
  check "model $model: sanitised to [unknown]" "ok|unknown" "$(core_both "$MOCK_URL" "" "[r.status, r.model].join('|')")"
done <<<"$META_MODELS"
check "fixture: all seven metacharacter/separator model rows ran (non-vacuity)" "7" "$META_N"
case_end
case_begin "c-sanitize-tokens-table" "hooks/lib/jev/provider-core.js"
# COST_PER_INPUT_TOKEN_USD is not exported; this mirrors hooks/lib/jev/provider-core.js L16
# (`const COST_PER_INPUT_TOKEN_USD = 0.042 / 1e6;`), and the drift guard below pins that line.
COST_EXPR='(0.042 / 1e6)'
check "drift guard: provider-core.js still defines COST_PER_INPUT_TOKEN_USD = 0.042 / 1e6" "1" \
  "$(grep -c -F 'const COST_PER_INPUT_TOKEN_USD = 0.042 / 1e6;' "$PROVIDER_JS")"
# est_cost_usd column: null, 0 (input 0 -> exactly 0), exact (=== input_tokens * cost), else mismatch.
COST_COL="r.est_cost_usd === null ? 'null' : (r.input_tokens === 0 && r.est_cost_usd === 0 ? '0' : (r.est_cost_usd === r.input_tokens * $COST_EXPR ? 'exact' : 'mismatch:' + r.est_cost_usd))"
while IFS='|' read -r name usage want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  raw_mode "{$OKANS,\"model\":\"jev-1.13.0\",\"usage\":$usage}"
  check "usage $name: input_tokens|est_cost_usd -> [$want]" "ok|$want" \
    "$(core_both "$MOCK_URL" "" "[r.status, String(r.input_tokens), $COST_COL].join('|')")"
done <<'TABLE'
zero           | {"input_tokens":0}                 | 0|0
one-point-zero | {"input_tokens":1.0}               | 1|exact
negative       | {"input_tokens":-1}                | null|null
fractional     | {"input_tokens":1.5}               | null|null
string         | {"input_tokens":"5"}               | null|null
null           | {"input_tokens":null}              | null|null
boolean        | {"input_tokens":true}              | null|null
max-safe       | {"input_tokens":9007199254740991}  | 9007199254740991|exact
max-safe-plus-1| {"input_tokens":9007199254740992}  | null|null
overflow       | {"input_tokens":1e400}             | null|null
usage-null     | null                               | null|null
usage-string   | "x"                                | null|null
TABLE
case_end

echo "=== JSON that parses but has the wrong shape is bad-response ==="
case_begin "c-run-wrong-shape-table" "hooks/lib/jev/provider-core.js"
raw_mode "{$OKANS}"
check "fixture: raw mode with a well-formed body is ok (non-vacuity)" "ok" "$(core_both "$MOCK_URL" "" "r.status")"
while IFS='|' read -r name body; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; body="${body# }"
  raw_mode "$body"
  check "body $name: bad-response, http_status null, latency_ms finite and >= 0, exactly three keys" \
    "bad-response|true|true|http_status,latency_ms,status" \
    "$(core_both "$MOCK_URL" "" "[r.status, r.http_status === null, typeof r.latency_ms === 'number' && Number.isFinite(r.latency_ms) && r.latency_ms >= 0, $RUN_KEYS].join('|')")"
done <<'TABLE'
null           | null
number         | 42
string         | "str"
array          | []
empty-object   | {}
answers-null   | {"answers":null}
answers-string | {"answers":"x"}
answers-zero   | {"answers":0}
empty-body     |
TABLE
case_end

echo "=== the pre hook sends the plan named by the cwd's WORKTREE_NOTES when the hook session id has none ==="
case_begin "c-pre-hook-plan-via-worktree-notes" "hooks/jev-shadow-pre.js"
fx_new c-wsid
WS_SID="jev2460-c-wsid"
printf '# Intent\nWSID-INTENT-MARK-2460\n' > "$FX/plans/$WS_SID-intent.md"
mkdir -p "$FX/wscwd"
printf '# Worktree Notes\n\nSession-ID: %s\n' "$WS_SID" > "$FX/wscwd/WORKTREE_NOTES.md"
# C12: the notes Session-ID is adopted only when its workflow state is bound to the hook cwd.
check "fixture: the WORKTREE_NOTES session has a workflow state" "outline" "$(hq seed-step "$WS_SID" outline)"
check "fixture: the WORKTREE_NOTES session's state is bound to the notes cwd" "$(np "$FX/wscwd")" \
  "$(hq bind-worktree "$WS_SID" "$(np "$FX/wscwd")")"
# sent_has_mark: whether the state in the last Jev request body carries the wsid intent text.
sent_has_mark() { hq mock-q "$(np "$MOCK_REQ")" "reqs.filter(q => q.path === '/v1/systemone').map(q => JSON.parse(q.body_text).state.includes('WSID-INTENT-MARK-2460')).join(',')"; }
# pre_with_cwd <hook-sid> <tid> <cwd>: one pre hook run whose payload cwd is <cwd>.
pre_with_cwd() {
  mock_mode '{"capture":true}'
  mkpayload "$FX/io/pre-$2.json" pre "$1" "$2"
  hq json-set "$(np "$FX/io/pre-$2.json")" cwd "\"$(np "$3")\""
  run_hook pre "$FX/io/pre-$2.json"
}
pre_with_cwd "$WS_SID" toolu_c_ws_ctl "$FX/cwd"
check "control: a hook session id that has the plan sends it (the harness sees the request body)" "true" "$(sent_has_mark)"
pre_with_cwd jev2460-c-hooksid toolu_c_ws_fallback "$FX/wscwd"
check "hook sid differs from the notes sid, payload.cwd holds WORKTREE_NOTES: the notes sid's intent text is sent" "true" "$(sent_has_mark)"
pre_with_cwd jev2460-c-hooksid toolu_c_ws_nocwd "$FX/cwd"
check "same hook sid, payload.cwd without WORKTREE_NOTES: the plan is not sent" "false" "$(sent_has_mark)"
case_end

finish
