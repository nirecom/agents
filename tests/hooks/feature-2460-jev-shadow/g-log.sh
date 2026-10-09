#!/usr/bin/env bash
# Tests: hooks/lib/jev/decision-record.js, hooks/jev-shadow-post.js, hooks/lib/jsonl-rotating-log.js
# Tags: TL2, hooks, jev, decision-log, schema-v1, no-raw-content, fail-open, scope:issue-specific, pwsh-not-required, observed-llm, untrusted-claim-content, table-driven, observed-jev, observed-input, observed-pending, latency-bound, s1b-without-s1, compare

# The decision log is the PoC's evidence, so its v1 schema is pinned field by field, and
# it must never hold raw prompts or plan artifacts -- only their size and hash. Logging is
# best effort: an unwritable log dir must not break the dispatch or make the hook print.

# TL3 gap (what this test does NOT catch): log growth over weeks of real use; rotation
# itself is covered by tests/hooks/feature-2460-jsonl-rotating-log.sh.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

echo "=== no raw content, only size and hash ==="
case_begin "g-no-raw-prompt-or-artifact" "hooks/lib/jev/decision-record.js"
fx_new g-raw
SID="jev2460-g-raw"
printf '# Intent\nINTENT-SECRET-MARK-2460\n' > "$FX/plans/$SID-intent.md"
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_g_raw --prompt "Judge this. PROMPT-SECRET-MARK-2460"
mkpayload "$FX/io/post.json" post "$SID" toolu_g_raw --prompt "Judge this. PROMPT-SECRET-MARK-2460"
run_hook pre "$FX/io/pre.json"
run_hook post "$FX/io/post.json"
check "one record was written (non-vacuity for the absence checks)" "1" "$(rq toolu_g_raw 'recs.length')"
check "neither the prompt marker nor the intent marker reaches the state dir" "absent|absent" \
  "$(grep_absent PROMPT-SECRET-MARK-2460 "$FX/state")|$(grep_absent INTENT-SECRET-MARK-2460 "$FX/state")"
check "input carries bytes > 0, a sha256 hex, truncated false and a sources array" "true|true|false|true" \
  "$(rq toolu_g_raw 'r && [Number.isInteger(r.input.bytes) && r.input.bytes > 0, /^[0-9a-f]{64}$/.test(r.input.sha256), r.input.truncated, Array.isArray(r.input.sources)].join("|")')"
case_end

echo "=== schema v1 field sets ==="
case_begin "g-schema-v1-keys" "hooks/lib/jev/decision-record.js"
check "top-level keys" \
  "adopted,agreement,agreement_by_signal,fallback_reason,input,jev,llm,mode,point,session_id,stage,step,tool_use_id,ts,v" \
  "$(rq toolu_g_raw 'r && Object.keys(r).sort().join(",")')"
check "jev keys" \
  "answer,est_cost_usd,http_status,input_tokens,latency_ms,min_confidence,model,probabilities,status" \
  "$(rq toolu_g_raw 'r && Object.keys(r.jev).sort().join(",")')"
check "llm keys" "answer,executor,executor_model,latency_ms,status" \
  "$(rq toolu_g_raw 'r && Object.keys(r.llm).sort().join(",")')"
check "input keys" "bytes,sha256,sources,truncated" "$(rq toolu_g_raw 'r && Object.keys(r.input).sort().join(",")')"
check "ts is an ISO timestamp; latencies are non-negative integers" "true|true|true" \
  "$(rq toolu_g_raw 'r && [!Number.isNaN(Date.parse(r.ts)), Number.isInteger(r.jev.latency_ms) && r.jev.latency_ms >= 0, Number.isInteger(r.llm.latency_ms) && r.llm.latency_ms >= 0].join("|")')"
check "probabilities are keyed by signal id, one per id" "$SIGNAL_CSV" \
  "$(rq toolu_g_raw 'r && Object.keys(r.jev.probabilities).join(",")')"
case_end

echo "=== executor fields ==="
case_begin "g-executor-model" "hooks/lib/jev/decision-record.js"
fx_new g-exec
SID="jev2460-g-exec"
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_g_model --model haiku
mkpayload "$FX/io/post.json" post "$SID" toolu_g_model --model haiku
run_hook pre "$FX/io/pre.json"; run_hook post "$FX/io/post.json"
check "executor is complexity-judge; tool_input.model wins" "complexity-judge|haiku" \
  "$(rq toolu_g_model 'r && [r.llm.executor, r.llm.executor_model].join("|")')"
FM_MODEL="$(sed -n 's/^model:[[:space:]]*//p' "$SCRIPT_CHECKOUT_ROOT/agents/complexity-judge.md" | head -n 1 | tr -d '\r')"
pair "$SID" toolu_g_fmmodel
check "without tool_input.model, the agent frontmatter model is used" "$FM_MODEL" \
  "$(rq toolu_g_fmmodel 'r && r.llm.executor_model')"
case_end

echo "=== fallback_reason is an enum value or null ==="
case_begin "g-fallback-reason-enum" "hooks/lib/jev/decision-record.js"
fx_new g-enum
SID="jev2460-g-enum"
for m in '{}' '{"systemone":"http:429"}' '{"systemone":"badjson"}' '{"answers":{"S2-architecture":0.6}}' '{"systemone":"outofrange"}'; do
  mock_mode "$m"
  pair "$SID" "toolu_g_enum_$RANDOM$RANDOM"
done
check "every record: fallback_reason null iff jev ok, else equal to jev.status (enum)" "5|true" \
  "$(hq qa "$(np "$LOG")" 'recs.length + "|" + recs.every(r => { const E = ["low-confidence","unmappable","breaker-open","not-run","no-key","unreachable","timeout","http-error","bad-response"]; return r.jev.status === "ok" ? r.fallback_reason === null : (E.includes(r.fallback_reason) && r.fallback_reason === r.jev.status); })')"
check "the five modes produced ok, http-error, bad-response, low-confidence, unmappable" \
  "bad-response,http-error,low-confidence,ok,unmappable" \
  "$(hq qa "$(np "$LOG")" 'recs.map(r => r.jev.status).sort().join(",")')"
case_end

echo "=== logging is fail-open ==="
case_begin "g-unwritable-log-dir-fail-open" "hooks/jev-shadow-post.js"
fx_new g-failopen
SID="jev2460-g-failopen"
mock_mode '{}'
printf 'not a directory\n' > "$FX/state/logs"
pair "$SID" toolu_g_failopen
check "logs/ is a file: post still exits 0" "0" "$HOOK_RC"
check "logs/ is a file: post writes nothing to stdout, the observed llm side is kept for a retry" "empty|1" \
  "$(stdout_state)|$(find "$JEVDIR/$SID/pending" -name 'toolu_g_failopen.claimed-*' 2>/dev/null | wc -l | tr -d ' ')"
case_end

echo "=== observedLlm: a claim's llm_observed is untrusted file content ==="
case_begin "g-observed-llm-table" "hooks/lib/jev/decision-record.js"
OBS_JS="$TMPROOT/observed-llm.js"
# Each row: name, input, expected JSON of observedLlm(input) (null = fall back to "missing").
cat > "$OBS_JS" <<'JS'
"use strict";
const { observedLlm } = require(process.argv[2]);
const ESC = String.fromCharCode(27);
const pad = (n) => "S1-multi-file" + " ".repeat(n - "S1-multi-file".length);
const ok = (o) => Object.assign({ status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: 10 }, o);
const rows = [
  ["valid-ok", ok({ answer: "S1-multi-file,S2-architecture", latency_ms: 1234 }), { status: "ok", answer: "S1-multi-file,S2-architecture", executor_model: "opus", latency_ms: 1234 }],
  ["valid-parse-fallback", ok({ status: "parse-fallback", answer: "S0-undecidable" }), { status: "parse-fallback", answer: "S0-undecidable", executor_model: "opus", latency_ms: 10 }],
  ["valid-missing-null", ok({ status: "missing", answer: null, latency_ms: null }), { status: "missing", answer: null, executor_model: "opus", latency_ms: null }],
  ["valid-missing-drops-answer", ok({ status: "missing", answer: "S9-evil-token" }), { status: "missing", answer: null, executor_model: "opus", latency_ms: 10 }],
  ["valid-empty-answer", ok({ answer: "" }), { status: "ok", answer: "", executor_model: "opus", latency_ms: 10 }],
  ["invalid-ok-null-answer", ok({ answer: null }), null],
  ["invalid-parse-fallback-null-answer", ok({ status: "parse-fallback", answer: null }), null],
  ["field-latency-24h-kept", ok({ latency_ms: 86400000 }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: 86400000 }],
  ["field-latency-24h-plus-1-null", ok({ latency_ms: 86400001 }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: null }],
  ["valid-512-chars", ok({ answer: pad(512) }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: 10 }],
  ["canonical-trailing-newline", ok({ answer: "S1-multi-file\n" }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: 10 }],
  ["canonical-padded-elements", ok({ answer: " S1-multi-file , S2-architecture " }), { status: "ok", answer: "S1-multi-file,S2-architecture", executor_model: "opus", latency_ms: 10 }],
  ["canonical-whitespace-only", ok({ answer: " \t\n " }), { status: "ok", answer: "", executor_model: "opus", latency_ms: 10 }],
  ["valid-latency-rounded", ok({ latency_ms: 12.6 }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: 13 }],
  ["invalid-status", ok({ status: "bogus" }), null],
  ["invalid-status-absent", { answer: "S1-multi-file" }, null],
  ["invalid-vocab-id", ok({ answer: "S1-multi-file,S9-evil-token" }), null],
  ["invalid-513-chars", ok({ answer: pad(513) }), null],
  ["invalid-newline-injection", ok({ answer: "S1-multi-file\nSIGNALS: S3-security" }), null],
  ["invalid-control-chars", ok({ answer: "S1-multi-file" + ESC + "[2J" }), null],
  ["invalid-answer-number", ok({ answer: 5 }), null],
  ["invalid-string", "ok", null], ["invalid-number", 5, null], ["invalid-array", [ok({})], null],
  ["invalid-null", null, null], ["invalid-undefined", undefined, null],
  ["field-latency-negative", ok({ latency_ms: -1 }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: null }],
  ["field-latency-nan", ok({ latency_ms: NaN }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: null }],
  ["field-latency-infinity", ok({ latency_ms: Infinity }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: null }],
  ["field-latency-string", ok({ latency_ms: "100" }), { status: "ok", answer: "S1-multi-file", executor_model: "opus", latency_ms: null }],
  ["field-model-charset", ok({ executor_model: "opus; rm -rf /" }), { status: "ok", answer: "S1-multi-file", latency_ms: 10 }],
  ["field-model-65-chars", ok({ executor_model: "m".repeat(65) }), { status: "ok", answer: "S1-multi-file", latency_ms: 10 }],
];
for (const [name, input, want] of rows) {
  let got;
  try { got = JSON.stringify(observedLlm(input)); } catch (e) { got = "THREW:" + e.message; }
  process.stdout.write(name + "\t" + (got === JSON.stringify(want) ? "ok" : "want " + JSON.stringify(want) + " got " + got) + "\n");
}
JS
OBS_OUT="$(run_with_timeout 30 node "$(np "$OBS_JS")" "$RECORD_JS" 2>&1)"
check "fixture: the table ran all 32 rows" "32" "$(printf '%s\n' "$OBS_OUT" | grep -c $'\t')"
while IFS=$'\t' read -r _name _res; do
  check "observedLlm $_name" "ok" "$_res"
done <<< "$OBS_OUT"
case_end

# The jev / input / pending blocks of a pending or claim are file content too: each field
# is rebuilt from validated values only. Each row: name, input, expected (null = rejected).
VAL_JS="$TMPROOT/observed-validators.js"
cat > "$VAL_JS" <<'JS'
"use strict";
const rec = require(process.argv[2]);
const IDS = process.argv[3].split(",");
const table = process.argv[4];
const probs = (o) => Object.fromEntries(IDS.map((id) => [id, o && id in o ? o[id] : null]));
const SHA = "ab".repeat(32);
const jIn = (o) => Object.assign({ status: "ok", http_status: 200, answer: "S1-multi-file", probabilities: { "S1-multi-file": 0.9 },
  min_confidence: 0.9, latency_ms: 100, model: "jev-1", input_tokens: 1000, est_cost_usd: 0.01 }, o);
const jOut = (o) => Object.assign({ status: "ok", http_status: 200, answer: "S1-multi-file", probabilities: probs({ "S1-multi-file": 0.9 }),
  min_confidence: 0.9, latency_ms: 100, model: "jev-1", input_tokens: 1000, est_cost_usd: 0.01 }, o);
const iIn = (o) => Object.assign({ bytes: 100, sha256: SHA, truncated: true, sources: ["intent", "outline_plan"] }, o);
const iOut = iIn;
const EMPTY = { bytes: 0, sha256: null, truncated: false, sources: [] };
const stageSpy = (s) => (s === null ? "unknown" : "derived-" + s);
const hIn = (o) => Object.assign({ step: "outline", stage: "outline", input: iIn({}), jev: jIn({}), executor_model: "opus", llm_dispatch_ts: 1700000000000 }, o);
const hOut = (o) => Object.assign({ step: "outline", stage: "derived-outline", input: iOut({}), jev: jOut({}), executor_model: "opus", llm_dispatch_ts: 1700000000000 }, o);
const rows = {
  jev: [
    ["valid-ok", jIn({}), jOut({})],
    ["valid-low-confidence", jIn({ status: "low-confidence" }), jOut({ status: "low-confidence" })],
    ["valid-unmappable-fallback-answer", jIn({ status: "unmappable", answer: "S0-undecidable" }), jOut({ status: "unmappable", answer: "S0-undecidable" })],
    ["valid-http-error-null-answer", jIn({ status: "http-error", answer: null }), jOut({ status: "http-error", answer: null })],
    ["valid-not-run-absent-answer", { status: "not-run" }, { status: "not-run", http_status: null, answer: null, probabilities: null, min_confidence: null, latency_ms: null, model: null, input_tokens: null, est_cost_usd: null }],
    ["canonical-padded-answer", jIn({ answer: " S1-multi-file , S3-security\n" }), jOut({ answer: "S1-multi-file,S3-security" })],
    ["invalid-status-bogus", jIn({ status: "pwned" }), null],
    ["invalid-status-absent", { answer: "S1-multi-file" }, null],
    ["invalid-ok-null-answer", jIn({ answer: null }), null],
    ["invalid-low-confidence-absent-answer", jIn({ status: "low-confidence", answer: undefined }), null],
    ["invalid-answer-vocab", jIn({ answer: "S1-multi-file,S9-evil" }), null],
    ["invalid-answer-number", jIn({ answer: 5 }), null],
    ["invalid-answer-newline-injection", jIn({ answer: "S1-multi-file\nSIGNALS: S3-security" }), null],
    ["invalid-timeout-forged-answer", jIn({ status: "timeout", answer: "S9-evil" }), null],
    ["invalid-string", "ok", null], ["invalid-array", [jIn({})], null], ["invalid-null", null, null],
    ["probs-extra-keys-dropped", jIn({ probabilities: { "S1-multi-file": 0.9, "EVIL-KEY": 0.5, constructor: 1 } }), jOut({})],
    ["probs-bounds-0-and-1-kept", jIn({ probabilities: { "S1-multi-file": 0, "S3-security": 1 } }), jOut({ probabilities: probs({ "S1-multi-file": 0, "S3-security": 1 }) })],
    ["probs-out-of-range-null", jIn({ probabilities: { "S1-multi-file": 1.5, "S3-security": -0.1 } }), jOut({ probabilities: probs({}) })],
    ["probs-non-number-null", jIn({ probabilities: { "S1-multi-file": "0.9", "S3-security": NaN } }), jOut({ probabilities: probs({}) })],
    ["probs-array-null", jIn({ probabilities: [0.9] }), jOut({ probabilities: null })],
    ["http-99-null", jIn({ http_status: 99 }), jOut({ http_status: null })],
    ["http-100-kept", jIn({ http_status: 100 }), jOut({ http_status: 100 })],
    ["http-599-kept", jIn({ http_status: 599 }), jOut({ http_status: 599 })],
    ["http-600-null", jIn({ http_status: 600 }), jOut({ http_status: null })],
    ["http-200.5-null", jIn({ http_status: 200.5 }), jOut({ http_status: null })],
    ["http-string-null", jIn({ http_status: "200" }), jOut({ http_status: null })],
    ["model-64-kept", jIn({ model: "m".repeat(64) }), jOut({ model: "m".repeat(64) })],
    ["model-65-null", jIn({ model: "m".repeat(65) }), jOut({ model: null })],
    ["model-charset-null", jIn({ model: "jev; rm -rf /" }), jOut({ model: null })],
    ["tokens-nan-null", jIn({ input_tokens: NaN }), jOut({ input_tokens: null })],
    ["tokens-infinity-null", jIn({ input_tokens: Infinity }), jOut({ input_tokens: null })],
    ["tokens-negative-null", jIn({ input_tokens: -1 }), jOut({ input_tokens: null })],
    ["tokens-fraction-null", jIn({ input_tokens: 1.5 }), jOut({ input_tokens: null })],
    ["tokens-max-kept", jIn({ input_tokens: 1e8 }), jOut({ input_tokens: 1e8 })],
    ["tokens-over-max-null", jIn({ input_tokens: 1e8 + 1 }), jOut({ input_tokens: null })],
    ["cost-nan-null", jIn({ est_cost_usd: NaN }), jOut({ est_cost_usd: null })],
    ["cost-infinity-null", jIn({ est_cost_usd: Infinity }), jOut({ est_cost_usd: null })],
    ["cost-negative-null", jIn({ est_cost_usd: -0.01 }), jOut({ est_cost_usd: null })],
    ["cost-max-kept", jIn({ est_cost_usd: 1000 }), jOut({ est_cost_usd: 1000 })],
    ["cost-over-max-null", jIn({ est_cost_usd: 1000.01 }), jOut({ est_cost_usd: null })],
    ["min-confidence-over-1-null", jIn({ min_confidence: 1.5 }), jOut({ min_confidence: null })],
    ["latency-24h-kept", jIn({ latency_ms: 86400000 }), jOut({ latency_ms: 86400000 })],
    ["latency-24h-plus-1-null", jIn({ latency_ms: 86400001 }), jOut({ latency_ms: null })],
  ],
  input: [
    ["valid", iIn({}), iOut({})],
    ["not-object-null", null, EMPTY], ["not-object-string", "x", EMPTY], ["not-object-array", [iIn({})], EMPTY],
    ["bytes-max-kept", iIn({ bytes: 1e7 }), iOut({ bytes: 1e7 })],
    ["bytes-over-max-0", iIn({ bytes: 1e7 + 1 }), iOut({ bytes: 0 })],
    ["bytes-negative-0", iIn({ bytes: -1 }), iOut({ bytes: 0 })],
    ["bytes-fraction-0", iIn({ bytes: 1.5 }), iOut({ bytes: 0 })],
    ["bytes-string-0", iIn({ bytes: "100" }), iOut({ bytes: 0 })],
    ["sha-63-null", iIn({ sha256: SHA.slice(1) }), iOut({ sha256: null })],
    ["sha-65-null", iIn({ sha256: SHA + "a" }), iOut({ sha256: null })],
    ["sha-uppercase-null", iIn({ sha256: SHA.toUpperCase() }), iOut({ sha256: null })],
    ["sha-non-hex-null", iIn({ sha256: "g" + SHA.slice(1) }), iOut({ sha256: null })],
    ["truncated-string-false", iIn({ truncated: "true" }), iOut({ truncated: false })],
    ["truncated-1-false", iIn({ truncated: 1 }), iOut({ truncated: false })],
    ["sources-charset-filtered", iIn({ sources: ["intent", "../x", "Intent", "a b", "x\ny", 5, null, "a".repeat(33), "a".repeat(32)] }), iOut({ sources: ["intent", "a".repeat(32)] })],
    ["sources-capped-at-8", iIn({ sources: "abcdefghij".split("") }), iOut({ sources: "abcdefgh".split("") })],
    ["sources-non-array-empty", iIn({ sources: "intent" }), iOut({ sources: [] })],
  ],
  pending: [
    ["valid", hIn({}), hOut({})],
    ["forged-stage-ignored", hIn({ stage: "EVIL-STAGE" }), hOut({})],
    ["forged-stage-without-step", hIn({ step: undefined, stage: "EVIL-STAGE" }), hOut({ step: null, stage: "unknown" })],
    ["step-traversal-null", hIn({ step: "../../escape" }), hOut({ step: null, stage: "unknown" })],
    ["step-64-kept", hIn({ step: "s".repeat(64) }), hOut({ step: "s".repeat(64), stage: "derived-" + "s".repeat(64) })],
    ["step-65-null", hIn({ step: "s".repeat(65) }), hOut({ step: null, stage: "unknown" })],
    ["step-dot-null", hIn({ step: "out.line" }), hOut({ step: null, stage: "unknown" })],
    ["step-newline-null", hIn({ step: "outline\nx" }), hOut({ step: null, stage: "unknown" })],
    ["step-number-null", hIn({ step: 5 }), hOut({ step: null, stage: "unknown" })],
    ["jev-forged-null", hIn({ jev: { status: "pwned" } }), hOut({ jev: null })],
    ["input-forged-empty", hIn({ input: "x" }), hOut({ input: EMPTY })],
    ["model-invalid-dropped", hIn({ executor_model: "opus; rm" }), hOut({ executor_model: undefined })],
    ["ts-zero-null", hIn({ llm_dispatch_ts: 0 }), hOut({ llm_dispatch_ts: null })],
    ["ts-negative-null", hIn({ llm_dispatch_ts: -5 }), hOut({ llm_dispatch_ts: null })],
    ["ts-string-null", hIn({ llm_dispatch_ts: "1000" }), hOut({ llm_dispatch_ts: null })],
    ["ts-infinity-null", hIn({ llm_dispatch_ts: Infinity }), hOut({ llm_dispatch_ts: null })],
    ["ts-nan-null", hIn({ llm_dispatch_ts: NaN }), hOut({ llm_dispatch_ts: null })],
    ["not-object-null", null, null], ["not-object-string", "x", null], ["not-object-array", [hIn({})], null],
  ],
};
const fn = { jev: rec.observedJev, input: rec.observedInput, pending: (v) => rec.observedPending(v, stageSpy) }[table];
for (const [name, input, want] of rows[table]) {
  let got;
  try { got = JSON.stringify(fn(input)); } catch (e) { got = "THREW:" + e.message; }
  process.stdout.write(name + "\t" + (got === JSON.stringify(want) ? "ok" : "want " + JSON.stringify(want) + " got " + got) + "\n");
}
JS
# run_val_table <table> <expected-row-count>
run_val_table() {
  local out _name _res
  out="$(run_with_timeout 30 node "$(np "$VAL_JS")" "$RECORD_JS" "$SIGNAL_CSV" "$1" 2>&1)"
  check "fixture: the $1 table ran all $2 rows" "$2" "$(printf '%s\n' "$out" | grep -c $'\t')"
  while IFS=$'\t' read -r _name _res; do
    check "observed $1: $_name" "ok" "$_res"
  done <<< "$out"
}

echo "=== observedJev: a pending's jev block is untrusted file content ==="
case_begin "g-observed-jev-table" "hooks/lib/jev/decision-record.js"
run_val_table jev 45
case_end

echo "=== observedInput: size, hash and sources only, each bounded ==="
case_begin "g-observed-input-table" "hooks/lib/jev/decision-record.js"
run_val_table input 18
case_end

echo "=== observedPending: step validated, stage re-derived, forged stage ignored ==="
case_begin "g-observed-pending-table" "hooks/lib/jev/decision-record.js"
run_val_table pending 20
case_end

echo "=== compare: S1b without S1 on either side disagrees; valid pairs keep the closure ==="
case_begin "g-compare-s1b-without-s1-table" "hooks/lib/jev/decision-record.js"
CMPT_JS="$TMPROOT/compare-s1b-table.js"
cat > "$CMPT_JS" <<'JS'
"use strict";
const { compare } = require(process.argv[2]);
const [name, js, ls, jstat] = process.argv.slice(3);
const c = compare({ status: jstat || "ok", answer: js }, { status: "ok", answer: ls });
const s = c.agreement_by_signal;
process.stdout.write(s ? [c.agreement, s["S1-multi-file"], s["S1b-wide-change"], s["S2-architecture"]].join(",") : String(c.agreement) + ",null");
JS
while IFS='|' read -r name jev llm want jstat; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  got="$(run_with_timeout 30 node "$(np "$CMPT_JS")" "$RECORD_JS" "$name" "$jev" "$llm" "$jstat" 2>&1)"
  check "compare $name: agreement,S1,S1b,S2" "$want" "$got"
done <<'TABLE'
jev-s1b-vs-llm-pair|S1b-wide-change|S1-multi-file,S1b-wide-change|false,false,true,true|
llm-s1b-vs-jev-pair|S1-multi-file,S1b-wide-change|S1b-wide-change|false,false,true,true|
both-s1b-only|S1b-wide-change|S1b-wide-change|false,false,true,true|
both-valid-pair|S1-multi-file,S1b-wide-change|S1-multi-file,S1b-wide-change|true,true,true,true|
both-s1-only|S1-multi-file|S1-multi-file|true,true,true,true|
both-none|||true,true,true,true|
s1-vs-pair|S1-multi-file|S1-multi-file,S1b-wide-change|false,true,false,true|
violation-with-s2|S1b-wide-change,S2-architecture|S1-multi-file,S1b-wide-change,S2-architecture|false,false,true,true|
none-vs-s1b-only||S1b-wide-change|false,false,false,true|
s1b-vs-s0-not-compared|S1b-wide-change|S0-undecidable|null,null|
s0-vs-s1b-not-compared|S0-undecidable|S1b-wide-change|null,null|
low-confidence-not-compared|S1b-wide-change|S1b-wide-change|null,null|low-confidence
TABLE
case_end

finish
