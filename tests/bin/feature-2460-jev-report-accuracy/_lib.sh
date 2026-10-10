#!/usr/bin/env bash
# Tests: bin/jev-report
# Tags: TL2, bin, jev, report, fixture, scope:issue-specific, pwsh-not-required
# Shared setup of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it once before
# the fragments (not standalone): one fixture dir, the report runner, the JSON / text
# evaluators, and the six-record two-generation fixture log FIX_LOG.

[ -n "${JEV_REPORT_LIB_LOADED:-}" ] && return 0
JEV_REPORT_LIB_LOADED=1
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-shadow/_lib.sh"
REPORT="$REPO_N/bin/jev-report"

fx_new report
FIX_LOG="$FX/fixture/jev-decisions.log"
mkdir -p "$FX/fixture"
# Six complexity-judge records (R1,R2 in .1; R3-R6 + other-point + a broken line in the base).
run_with_timeout 30 node -e '
  const fs = require("fs");
  const ids = process.argv[2].split(",");
  const probs = (over) => Object.fromEntries(ids.map((k) => [k, over[k] !== undefined ? over[k] : 0.02]));
  const bySig = (over) => Object.fromEntries(ids.map((k) => [k, over[k] !== undefined ? over[k] : true]));
  const rec = (n, o) => JSON.stringify(Object.assign({ v: 1, ts: "2026-10-01T00:00:0" + n + "Z", point: "complexity-judge",
    mode: "shadow", adopted: "llm", session_id: "sid-r" + n, step: o.stage, tool_use_id: "toolu_r" + n,
    input: { bytes: 10, sha256: "0".repeat(64), truncated: false, sources: [] } }, o.top || {}, {
    stage: o.stage,
    jev: Object.assign({ status: "ok", http_status: null, answer: "S1-multi-file", probabilities: probs({ "S1-multi-file": 0.97 }),
      min_confidence: 0.97, latency_ms: o.jl, model: "jev-1.13.0", input_tokens: 100, est_cost_usd: o.cost }, o.jev || {}),
    llm: Object.assign({ status: "ok", answer: "S1-multi-file", executor: "complexity-judge", executor_model: "opus", latency_ms: o.ll }, o.llm || {}),
    agreement: o.agr === undefined ? null : o.agr,
    agreement_by_signal: o.abs === undefined ? null : o.abs,
    fallback_reason: o.fr === undefined ? null : o.fr }));
  const R = [
    rec(1, { stage: "outline", jl: 100, ll: 1000, cost: 0.00001, agr: true, abs: bySig({}) }),
    rec(2, { stage: "detail", jl: 200, ll: 2000, cost: 0.00002, agr: false, abs: bySig({ "S2-architecture": false }),
      llm: { answer: "S1-multi-file,S2-architecture" } }),
    rec(3, { stage: "outline", jl: 300, ll: 3000, cost: 0.00003, fr: "low-confidence",
      jev: { status: "low-confidence", answer: "S0-undecidable", min_confidence: 0.6, probabilities: probs({ "S1-multi-file": 0.97, "S2-architecture": 0.6 }) } }),
    rec(4, { stage: "cos1", jl: 400, ll: null, cost: 0.00004, llm: { status: "missing", answer: null } }),
    rec(5, { stage: "unknown", jl: 500, ll: 5000, cost: 0.00005, llm: { status: "parse-fallback", answer: "S0-undecidable" } }),
    rec(6, { stage: "write_code", jl: 600, ll: 6000, cost: null, fr: "http-error",
      jev: { status: "http-error", http_status: 500, answer: null, probabilities: null, min_confidence: null, model: null, input_tokens: null } }),
  ];
  const other = rec(7, { stage: "outline", jl: 1, ll: 1, cost: 0.5, agr: true, abs: bySig({}), top: { point: "other-point" } });
  fs.writeFileSync(process.argv[1] + ".1", R.slice(0, 2).join("\n") + "\n");
  fs.writeFileSync(process.argv[1], R.slice(2).join("\n") + "\n{not json at all\n" + other + "\n");
' "$(np "$FIX_LOG")" "$SIGNAL_CSV" 2>/dev/null

# report <out-file> [args...]: run jev-report; sets REP_RC, stderr in $FX/io/report.err.
report() {
  local out="$1"; shift
  (cd "$FX/cwd" && bash "$RWT" 60 node "$REPORT" "$@" > "$out" 2> "$FX/io/report.err")
  REP_RC=$?
}
J="$FX/io/report.json"
# P expands inside larger expressions, so it is parenthesised; {} makes a missing point read as undefined fields.
P='((o && o.points && o.points["complexity-judge"]) || {})'
jx() { hq json-expr "$(np "$J")" "$1"; }
# tx <expr>: evaluate <expr> with text = the text report at $T and lines = its lines.
tx() {
  run_with_timeout 30 node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8");
    const lines = text.replace(/\n$/, "").split("\n");
    process.stdout.write(String(eval(process.argv[2])));
  ' "$(np "$T")" "$1" 2>/dev/null
}
