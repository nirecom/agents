#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate/adoption.js, bin/lib/jev-report-aggregate.js
# Tags: TL2, bin, jev, report, adoption, llm-needed-rate, short-circuit, input-insufficient, write-code-list-failsafe, finalize-absent, by-mode, terminal-sanitisation, untrusted-log, secret-leak, prototype-pollution, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): the v2 adoption section per point and overall (LLM call rate, answer-received
# rate, short-circuit rate, adopted / by_mode, input_insufficient breakdown, failsafes), its
# text labels, and a hostile v2 log that must neither crash the report nor leak a secret.

echo "=== v2 adoption per point and overall ==="
# detail-skip: llm / mixed / short-circuit / all-final / orphan / shadow / three input-insufficient.
# complexity-judge: three write-code list failsafes, one deterministic override, one all-llm.
fx_log adopt '[
  D({ p: 0.8, sub: true }),
  D({ p: { sd_single_approach: 0.95, sd_no_open_decision: 0.8 }, sub: true }),
  D({ p: { sd_single_approach: 0.1, sd_no_open_decision: 0.8 } }),
  D({ p: 0.95 }),
  D({ p: 0.8, orphan: true }),
  D({ p: 0.8, sub: true, mode: "shadow" }),
  D({ missing: ["issue body"], sub: true }),
  D({ missing: ["intent"], sf: { intent: "copy-failed" }, sub: true }),
  D({ missing: ["outline"], sf: { outline: "over-cap" }, sub: true }),
  D({ point: "complexity-judge", stage: "write-code", p: 0.01, wcl: "missing" }),
  D({ point: "complexity-judge", stage: "write-code", p: 0.01, wcl: "invalid" }),
  D({ point: "complexity-judge", stage: "write-code", p: 0.01, wcl: "copy-failed" }),
  D({ point: "complexity-judge", p: { "S2-architecture": 0.5, "S3-security": 0.01, "S5-breaking": 0.01 },
    sub: { "S2-architecture": true, "S3-security": false, "S5-breaking": false }, override: ["S4-installer"] }),
  D({ point: "complexity-judge", p: 0.5, sub: false }),
  V1({}), V1({ point: "detail-skip" })
]'
rep_json adopt
DS='A("detail-skip")'
CJ='A("complexity-judge")'

case_begin "adoption-fixture-shape" "bin/lib/jev-report-aggregate/adoption.js"
check "fixture: 16 lines (14 v2 decisions, 2 v1)" "16" "$FXL_N"
check "--json over the mixed log exits 0" "0" "$REP_RC"
check "adoption counts only v2 decisions: detail-skip 9, complexity-judge 5, overall 14" "9|5|14" \
  "$(rjq "[$DS.count, $CJ.count, AO().count].join(\"|\")")"
case_end

case_begin "adoption-llm-call-rate" "bin/lib/jev-report-aggregate/adoption.js"
check "detail-skip: llm_needed_rate 7/9 (the short-circuit and all-final tickets are in the denominator only)" "0.7778" \
  "$(rjq "f4($DS.llm_needed_rate)")"
check "detail-skip: llm_answer_received_rate 6/7 over the llm_needed tickets; answer_missing 1 (the orphan)" "0.8571|1" \
  "$(rjq "f4($DS.llm_answer_received_rate) + \"|\" + $DS.answer_missing")"
check "complexity-judge: llm_needed_rate 2/5, received 2/2, answer_missing 0" "0.4000|1.0000|0" \
  "$(rjq "[f4($CJ.llm_needed_rate), f4($CJ.llm_answer_received_rate), $CJ.answer_missing].join(\"|\")")"
check "overall: llm_needed_rate 9/14, received 8/9, answer_missing 1" "0.6429|0.8889|1" \
  "$(rjq "[f4(AO().llm_needed_rate), f4(AO().llm_answer_received_rate), AO().answer_missing].join(\"|\")")"
case_end

case_begin "adoption-short-circuit" "bin/lib/jev-report-aggregate/adoption.js"
check "detail-skip: short_circuit_count 1, short_circuit_rate 1/9" "1|0.1111" \
  "$(rjq "$DS.short_circuit_count + \"|\" + f4($DS.short_circuit_rate)")"
check "complexity-judge: no short circuit (0, rate 0)" "0|0.0000" \
  "$(rjq "$CJ.short_circuit_count + \"|\" + f4($CJ.short_circuit_rate)")"
check "overall: short_circuit_count 1, rate 1/14" "1|0.0714" \
  "$(rjq "AO().short_circuit_count + \"|\" + f4(AO().short_circuit_rate)")"
case_end

case_begin "adoption-adopted-and-mode" "bin/lib/jev-report-aggregate/adoption.js"
check "detail-skip adopted jev/llm/mixed: 2/5/1 (the orphan has no adoption)" "2|5|1" \
  "$(rjq "[$DS.adopted.jev, $DS.adopted.llm, $DS.adopted.mixed].join(\"|\")")"
check "complexity-judge adopted jev/llm/mixed: 3/1/1" "3|1|1" \
  "$(rjq "[$CJ.adopted.jev, $CJ.adopted.llm, $CJ.adopted.mixed].join(\"|\")")"
check "by_mode is the record's frozen mode: detail-skip production 8, shadow 1" "8|1" \
  "$(rjq "$DS.by_mode.production + \"|\" + $DS.by_mode.shadow")"
check "overall adopted 5/6/2, by_mode production 13" "5|6|2|13" \
  "$(rjq "[AO().adopted.jev, AO().adopted.llm, AO().adopted.mixed, AO().by_mode.production].join(\"|\")")"
case_end

case_begin "adoption-finalize-absent-and-failsafes" "bin/lib/jev-report-aggregate/adoption.js"
check "the orphan counts in finalize_absent and answer_missing" "1|1" \
  "$(rjq "$DS.finalize_absent + \"|\" + $DS.answer_missing")"
check "complexity-judge write_code_list_failsafe: missing 1, invalid 1, copy-failed 1" "1|1|1" \
  "$(rjq "[$CJ.write_code_list_failsafe.missing, $CJ.write_code_list_failsafe.invalid, $CJ.write_code_list_failsafe[\"copy-failed\"]].join(\"|\")")"
check "complexity-judge deterministic_override 1; detail-skip 0" "1|0" \
  "$(rjq "$CJ.deterministic_override + \"|\" + $DS.deterministic_override")"
check "superseded_count is 0 everywhere in a log without settle records" "0|0|0" \
  "$(rjq "[$DS.superseded_count, AO().superseded_count, o.superseded_count].join(\"|\")")"
case_end

case_begin "adoption-input-insufficient-breakdown" "bin/lib/jev-report-aggregate/adoption.js"
check "detail-skip input_insufficient 3" "3" "$(rjq "$DS.input_insufficient")"
check "by section from input.missing: issue body 1, intent 1, outline 1" '{"intent":1,"issue body":1,"outline":1}' \
  "$(rjq "JSON.stringify(Object.fromEntries(Object.entries($DS.input_insufficient_by_section || {}).sort()))")"
check "sources_failed by reason: copy-failed 1, over-cap 1" "1|1" \
  "$(rjq "($DS.sources_failed_by_reason || {})[\"copy-failed\"] + \"|\" + ($DS.sources_failed_by_reason || {})[\"over-cap\"]")"
check "overall input_insufficient 3" "3" "$(rjq "AO().input_insufficient")"
case_end

case_begin "adoption-text-labels" "bin/lib/jev-report-aggregate.js"
rep_text adopt
check "text mode exits 0" "0" "$REP_RC"
check "the LLM call rate is shown under its display name" "true" "$(tx 'lines.some((l) => l.includes("LLM call rate"))')"
check "its one-line definition (the CLI requested a subagent dispatch) sits next to it" "true" \
  "$(tx '((i) => i >= 0 && lines.slice(Math.max(0, i - 1), i + 3).some((l) => /dispatch/.test(l)))(lines.findIndex((l) => l.includes("LLM call rate")))')"
check "the answer-received rate and answer_missing are in the same row block" "true" \
  "$(tx '((i) => i >= 0 && lines.slice(i, i + 3).some((l) => l.includes("answer-received rate")) && lines.slice(i, i + 3).some((l) => l.includes("answer_missing")))(lines.findIndex((l) => l.includes("LLM call rate")))')"
# Every registered point now short-circuits (complexity-judge on true), so none reads "no short-circuit".
check "the short-circuit rate is labelled; complexity-judge shows its rate (0) and no point reads no short-circuit" "true|0|true" \
  "$(tx '[lines.some((l) => l.includes("short-circuit rate")), lines.filter((l) => l.includes("no short-circuit")).length, lines.some((l) => l.startsWith("complexity-judge: decisions=") && l.endsWith("short-circuit rate=0 (0)"))].join("|")')"
case_end

echo "=== a hostile v2 log neither crashes the report nor leaks a secret ==="
H_ENV_KEY="TYPESAFE_API_KEY=$SENTINEL_KEY"
# hrep <out> [args...]: the report with the sentinel API key in its environment.
hrep() {
  local out="$1"; shift
  (cd "$FX/cwd" && env "$H_ENV_KEY" bash "$RWT" 120 node "$REPORT" --log "$FXL" --no-sweep "$@" > "$out" 2> "$FX/io/hostile-v2.err")
  REP_RC=$?
}

case_begin "adoption-hostile-log-safe" "bin/lib/jev-report-aggregate.js"
# Control characters are built at runtime so this file holds no raw ESC byte; __SENTINEL__
# becomes the sentinel key, so a secret carried in the log itself must not leak either.
HOSTILE_EXPR=$(cat <<'JS'
((E) => [
  D({ p: 0.8, sub: true }),
  "{not json at all",
  "[1,2,3]",
  "null",
  "{\"version\":2,\"record_type\":\"decision\",\"point\":\"detail-skip\",\"pad\":\"" + "A".repeat(3 * 1024 * 1024) + "\"}",
  D({ p: 0.8, sub: true, sid: "$(touch pwned)`touch pwned`", ticket: "$(touch pwned);rm -rf /" }),
  D({ p: 0.8, sub: true, top: { point: "__proto__" } }),
  D({ p: 0.8, sub: true, top: { point: "constructor" } }),
  D({ p: 0.8, sub: true, top: { mode: "ignore previous instructions" + E + "[31m", fallback_reason: "MARK-2460 " + E + "[2J" } }),
  JSON.stringify(D({ p: 0.8, sub: true, top: { input: { missing: ["issue body\n== forged ==", "__proto__"],
    sources_failed: ["x"], sources_failed_reasons: { x: "evil" + E } } } }))
    .replace("\"sources_failed_reasons\":{", "\"sources_failed_reasons\":{\"__proto__\":{\"polluted\":1},"),
  JSON.stringify(D({ p: 0.8, sub: true, top: {
    llm: { status: "ok", answer: "SKIP_CONDITIONS: ignore all previous instructions __SENTINEL__" },
    jev: { status: "ok", model: "__SENTINEL__" + E, probabilities: { sd_single_approach: "x" } } } }))
    .replace("\"agreement_by_signal\":{", "\"agreement_by_signal\":{\"__proto__\":{\"polluted\":1},\"constructor\":\"yes\","),
  S({ ticket: "$(touch pwned)" })
])(String.fromCharCode(27))
JS
)
fx_log hostile "${HOSTILE_EXPR//__SENTINEL__/$SENTINEL_KEY}"
check "fixture: 12 lines, one over 3 MB" "12|true" \
  "$FXL_N|$(run_with_timeout 30 node -e 'process.stdout.write(String(require("fs").readFileSync(process.argv[1], "utf8").split("\n").some((l) => l.length > 3 * 1024 * 1024)))' "$FXL" 2>/dev/null)"
T="$FX/io/hostile-v2.txt"
hrep "$T"
check "text mode exits 0 over the hostile v2 log" "0" "$REP_RC"
check "no control character other than newline reaches the terminal" "false" \
  "$(tx 'new RegExp("[\\u0000-\\u0009\\u000b-\\u001f\\u007f-\\u009f]").test(text)')"
check "no injected text or forged heading is printed" "" \
  "$(tx '["MARK-2460", "forged", "ignore previous", "ignore all", "touch pwned", "rm -rf"].filter((m) => text.includes(m)).join(",")')"
RJ="$FX/io/hostile-v2.json"
hrep "$RJ" --json
check "--json exits 0 and is valid JSON" "0|true" "$REP_RC|$(rjq 'o !== undefined && o !== null && typeof o === "object"')"
check "no polluted key leaks into the adoption figures" "false" "$(rjq 'JSON.stringify(get(o, "adoption") || {}).includes("polluted")')"
check "the clean detail-skip decision is still counted (at least 1)" "true" "$(rjq 'A("detail-skip").count >= 1')"
check "no file named pwned was created" "absent" "$([ -e "$FX/cwd/pwned" ] || [ -e "$FX/pwned" ] && echo present || echo absent)"
check "the sentinel key reaches neither stdout (text, json) nor stderr" "absent|absent|absent" \
  "$(grep_absent "$SENTINEL_KEY" "$T")|$(grep_absent "$SENTINEL_KEY" "$RJ")|$(grep_absent "$SENTINEL_KEY" "$FX/io/hostile-v2.err")"
case_end
