#!/usr/bin/env bash
# tests/bin/feat-2490-next-step-gate/value-line.sh
# Tests: bin/workflow/lib/next-step/gate-line.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/parse-next-step-output.js, hooks/lib/confirm-gate/probe.js, hooks/lib/confirm-gate/step-gate-map.js, hooks/lib/config-flag.js
# Tags: tl2, workflow, confirm-gate, next-step, value-line, scope:issue-specific, pwsh-not-required
# #2490 (a)+(b): the display-only GATE_CONFIRM_<X> line and the token behind it (sync and async probe).

# TL3 gap (what this test does NOT catch): whether a live model treats the value line
# as display-only and still branches through next-step --gate. Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh
# category: skill-orchestration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2490-next-step-gate/common.sh"
STEPS_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/next-step/steps.js")"
skill_of() { node -e 'process.stdout.write(require(process.argv[1]).STEP_TO_SKILL[process.argv[2]])' "$STEPS_MOD" "$1"; }

echo "=== (a) every gate step: one value line, last, keyed to NEXT_SKILL ==="
case_begin "gate-steps-emit-one-last-value-line" "bin/workflow/lib/next-step/gate-line.js"
for step in $GATE_STEPS; do
  sid="vl-$step"
  write_state "$sid" "$(json_at "$step")"
  [ "$step" = "detail" ] && put_plan "$sid" intent "$INTENT_FULL"
  # #2654: the clarify_intent gate reads intent.md `## Issues`, not state.closes_issues.
  [ "$step" = "clarify_intent" ] && put_plan "$sid" intent "$(printf '## Issues\n- #2490')"
  ns --session "$sid"
  check "$step: ACTION=invoke" "invoke" "$(val ACTION)"
  check "$step: NEXT_SKILL is the step skill" "$(skill_of "$step")" "$(val NEXT_SKILL)"
  check "$step: exactly one GATE_CONFIRM_ line" 1 "$(count_re "$OUT" '^GATE_CONFIRM_')"
  check "$step: the value line is the last line" "GATE_$(gate_key_of "$step")=ON" "$(last_line "$OUT")"
  check "$step: cause ok -> no GATE_PROBE_CAUSE line" 0 "$(count_re "$OUT" '^GATE_PROBE_CAUSE=')"
done
case_end

# Recorded step is outline, but CONFIRM_OUTLINE=off in .env plus outline.md lets the
# snapshot resolve outline; the value line must follow NEXT_SKILL (detail), not the record.
case_begin "snapshot-advanced-key-follows-next-skill" "bin/workflow/lib/next-step/verdict.js"
sid="vl-adv"
printf 'CONFIRM_OUTLINE=off\n' > "$CFG/.env"
export CONFIRM_OUTLINE=off
write_state "$sid" "$(json_at outline)"
put_plan "$sid" intent "$INTENT_FULL"; put_plan "$sid" outline "## Adopted approach"
ns --session "$sid"
check "advanced: NEXT_SKILL=make-detail-plan" "make-detail-plan" "$(val NEXT_SKILL)"
check "advanced: value line names the detail gate" "GATE_CONFIRM_DETAIL=ON" "$(last_line "$OUT")"
check "advanced: no outline value line" 0 "$(count_re "$OUT" '^GATE_CONFIRM_OUTLINE=')"
: > "$CFG/.env"; export CONFIRM_OUTLINE=on
case_end

case_begin "non-gate-steps-keep-four-line-contract" "bin/workflow/lib/next-step/verdict.js"
for row in "research|survey-code" "review_tests|review-tests" "run_tests|run-tests"; do
  step="${row%%|*}"; skill="${row#*|}"
  write_state "vl-ng-$step" "$(json_at "$step")"
  ns --session "vl-ng-$step"
  want="$(printf "ACTION=invoke\nNEXT_SKILL=%s\nNEXT_HINT='Run /%s via the Skill tool.'\nREASON='%s'" "$skill" "$skill" "$step")"
  check "$step: output is the unchanged 4-line contract" "$want" "$OUT"
done
case_end

case_begin "terminal-paths-no-value-line" "bin/workflow/lib/next-step/verdict.js"
ns
check "no session: ACTION=blocked" "blocked" "$(val ACTION)"
check "no session: no value line" 0 "$(count_re "$OUT" '^GATE_')"
write_state vl-blk "$JSON_BLOCKED"; ns --session vl-blk
check "closes_issues empty (clarify_intent): ACTION=blocked" "blocked" "$(val ACTION)"
check "closes_issues empty: no value line" 0 "$(count_re "$OUT" '^GATE_')"
write_state vl-inc "$JSON_INCONSISTENT"; ns --session vl-inc
check "inconsistent (write_tests): ACTION=abort" "abort" "$(val ACTION)"
check "inconsistent: no value line" 0 "$(count_re "$OUT" '^GATE_')"
write_state vl-cor "$JSON_CORRUPT"; ns --session vl-cor
check "corrupt: ACTION=abort" "abort" "$(val ACTION)"
check "corrupt: no value line" 0 "$(count_re "$OUT" '^GATE_')"
write_state vl-done "$JSON_ALL_COMPLETE"; ns --session vl-done
check "all complete: ACTION=done" "done" "$(val ACTION)"
check "all complete: no value line" 0 "$(count_re "$OUT" '^GATE_')"
write_state vl-off "$(json_at write_tests)"; : > "$GT_BASE/workflow-state/vl-off.workflow-off"
ns --session vl-off
check "workflow-off at write_tests: ACTION=paused" "paused" "$(val ACTION)"
check "paused: no value line" 0 "$(count_re "$OUT" '^GATE_')"
case_end

case_begin "skip-hint-precedes-value-line" "bin/workflow/lib/next-step/verdict.js"
write_state vl-skip "$(json_at outline)"
put_plan vl-skip intent "Fix typo in the helper name."
ns --session vl-skip
check "skip-hint fixture: 6 lines" 6 "$(count_re "$OUT" '.')"
check "line 5 is SKIP_HINT" "SKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED" "$(printf '%s\n' "$OUT" | sed -n 5p)"
check "line 6 is the value line" "GATE_CONFIRM_OUTLINE=ON" "$(printf '%s\n' "$OUT" | sed -n 6p)"
case_end

case_begin "parser-accepts-value-line" "bin/workflow/lib/parse-next-step-output.js"
PARSED="$(PARSER="$(np "$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/parse-next-step-output.js")" run_with_timeout node - 2>/dev/null <<'EOF'
const { parseNextStepOutput } = require(process.env.PARSER);
const text = "ACTION=invoke\nNEXT_SKILL=make-outline-plan\nNEXT_HINT='Run /make-outline-plan via the Skill tool.'\n" +
  "REASON='outline'\nSKIP_HINT=WORKFLOW_OUTLINE_NOT_NEEDED\nGATE_CONFIRM_OUTLINE=OFF\n";
const r = parseNextStepOutput(text);
process.stdout.write([r.ACTION, r.NEXT_SKILL, r.NEXT_HINT, r.REASON, r.SKIP_HINT].join("|"));
EOF
)"
check "parser returns the 4 keys (+SKIP_HINT) with the value line present" \
  "invoke|make-outline-plan|Run /make-outline-plan via the Skill tool.|outline|WORKFLOW_OUTLINE_NOT_NEEDED" "$PARSED"
case_end

echo "=== (b) value half: env, .env, precedence, ERROR variants ==="
write_state vl-val "$(json_at write_tests)"
case_begin "env-value-maps-to-token" "bin/workflow/lib/next-step/gate-line.js"
export CONFIRM_TESTS=off; ns --session vl-val
check "env off -> OFF" "GATE_CONFIRM_TESTS=OFF" "$(last_line "$OUT")"
export CONFIRM_TESTS=on; ns --session vl-val
check "env on -> ON (sync exit 1 is not ERROR)" "GATE_CONFIRM_TESTS=ON" "$(last_line "$OUT")"
unset CONFIRM_TESTS; ns --session vl-val
check "unset everywhere -> ON" "GATE_CONFIRM_TESTS=ON" "$(last_line "$OUT")"
case_end

case_begin "dotenv-off-and-env-precedence" "bin/workflow/lib/next-step/gate-line.js"
printf 'CONFIRM_TESTS=off\n' > "$CFG/.env"
ns --session vl-val
check ".env off -> OFF" "GATE_CONFIRM_TESTS=OFF" "$(last_line "$OUT")"
check ".env off, cause ok -> no GATE_PROBE_CAUSE line" 0 "$(count_re "$OUT" '^GATE_PROBE_CAUSE=')"
export CONFIRM_TESTS=on; ns --session vl-val
check "env on beats .env off -> ON" "GATE_CONFIRM_TESTS=ON" "$(last_line "$OUT")"
: > "$CFG/.env"
case_end

# #2681: the probe resolves in-process through the tree's hooks/lib/config-flag.js, so a broken
# checkout is a missing config-flag.js or a load-env stub; bin/ stubs are never read.
# stub_load_env <tree> <fn>: load-env.js keeps every export (the original becomes
# load-env-real.js) and swaps resolveConfigVar for <fn>, which only touches CONFIRM_* keys
# so the rest of next-step keeps its real config.
stub_load_env() {
  mv "$1/hooks/lib/load-env.js" "$1/hooks/lib/load-env-real.js"
  printf '"use strict";\nconst real = require("./load-env-real");\nmodule.exports = Object.assign({}, real, { resolveConfigVar: function (n, d, o) { if (/^CONFIRM_/.test(n)) { %s } return real.resolveConfigVar(n, d, o); } });\n' "$2" > "$1/hooks/lib/load-env.js"
}
CFG_NOLIB="$GT_BASE/cfg-nolib"; mk_tree "$CFG_NOLIB"; rm -f "$CFG_NOLIB/hooks/lib/config-flag.js"
CFG_THROW="$GT_BASE/cfg-throw"; mk_tree "$CFG_THROW"
stub_load_env "$CFG_THROW" 'throw new Error("stub: resolveConfigVar throws");'
CFG_LOADFAIL="$GT_BASE/cfg-loadfail"; mk_tree "$CFG_LOADFAIL"
stub_load_env "$CFG_LOADFAIL" 'return { value: "off", loadFailed: true, source: "env-file" };'
CFG_SLOW="$GT_BASE/cfg-slow"; mk_tree "$CFG_SLOW"
stub_load_env "$CFG_SLOW" 'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);'
# A marked config-flag.js that answers off for every key: only a probe that reads its own tree's copy says OFF under CONFIRM_TESTS=on.
CFG_MARK="$GT_BASE/cfg-mark"; mk_tree "$CFG_MARK"
printf '"use strict";\nconst KINDS = ["off", "on", "unset", "unrecognized", "failed"];\nfunction classifyConfigFlag() { return { kind: "off", value: "marked-stub", cause: null }; }\nfunction verdictOfKind(k) { return k === "off" ? "OFF" : k === "failed" ? "ERROR" : "ON"; }\nmodule.exports = { KINDS, classifyConfigFlag, verdictOfKind, runCli() {} };\n' > "$CFG_MARK/hooks/lib/config-flag.js"
probe_of() { np "$1/hooks/lib/confirm-gate/probe.js"; }

case_begin "broken-checkout-error-variants" "hooks/lib/confirm-gate/probe.js"
for row in "no config-flag.js|exception|$CFG_NOLIB" "load-env throws|exception|$CFG_THROW" "load-env load failure|load-failed|$CFG_LOADFAIL"; do
  name="${row%%|*}"; rest="${row#*|}"; cause="${rest%%|*}"; tree="${rest#*|}"
  OUT="$(run_next_step_in "$tree" --session vl-val 2>/dev/null || true)"
  check "$name -> ERROR, value line last" "GATE_CONFIRM_TESTS=ERROR" "$(last_line "$OUT")"
  check "$name -> cause line right before the value line" "GATE_PROBE_CAUSE=$cause" \
    "$(printf '%s\n' "$OUT" | grep -B1 '^GATE_CONFIRM_TESTS=' | head -n 1)"
  OUT="$(run_next_step_in "$tree" --gate --session vl-val 2>/dev/null || true)"
  check "$name --gate -> REASON (last line) names probe-$cause" yes \
    "$(case "$(last_line "$OUT")" in REASON=*"probe-$cause"*) echo yes ;; *) echo no ;; esac)"
done
case_end

case_begin "unterminated-quote-env-keeps-value-and-secret" "hooks/lib/confirm-gate/probe.js"
CFG_UQ="$GT_BASE/cfg-uq"; mk_tree "$CFG_UQ"
printf 'CONFIRM_TESTS=off\nCF_SECRET="s3cr3t-value\nOTHER=1\n' > "$CFG_UQ/.env"
OUT="$(unset CONFIRM_TESTS; run_next_step_in "$CFG_UQ" --session vl-val 2>"$GT_BASE/uq-err" || true)"
check "unterminated quote after the key: value line still OFF" "GATE_CONFIRM_TESTS=OFF" "$(last_line "$OUT")"
check "unterminated quote: the value never reaches stderr" 0 "$(grep -c 's3cr3t-value' "$GT_BASE/uq-err" || true)"
case_end

# One node drives both probe flavours over the same inputs (CPR-ORTH); a broken row loads
# the probe of its own tree, because the probe reads the config-flag.js of the checkout it
# lives in. Each row prints name=token.
PROBE_OUT="$(PROBE_MOD="$(probe_of "$SCRIPT_CHECKOUT_ROOT")" PROBE_NOLIB="$(probe_of "$CFG_NOLIB")" \
  PROBE_THROW="$(probe_of "$CFG_THROW")" PROBE_SLOW="$(probe_of "$CFG_SLOW")" \
  PROBE_MARK="$(probe_of "$CFG_MARK")" run_with_timeout node - 2>/dev/null <<'EOF'
const e = process.env;
const out = (k, v) => process.stdout.write(k + "=" + v + "\n");
(async () => {
  let m;
  try { m = require(e.PROBE_MOD); } catch (err) { out("LOAD", "FAILED"); return; }
  const rows = [["off", e.PROBE_MOD, "off", 5000], ["on", e.PROBE_MOD, "on", 5000], ["err", e.PROBE_NOLIB, "on", 5000]];
  for (const [name, mod, v, t] of rows) {
    process.env.CONFIRM_TESTS = v;
    let s, a;
    try { s = require(mod).probeConfirmGateSync("CONFIRM_TESTS", t); } catch (x) { s = "THREW"; }
    try { a = await require(mod).probeConfirmGate("CONFIRM_TESTS", t); } catch (x) { a = "THREW"; }
    out("sync_" + name, s); out("async_" + name, a);
  }
  process.env.CONFIRM_TESTS = "off";
  const one = (k, f) => { try { out(k, f()); } catch (x) { out(k, "THREW"); } };
  one("sync_nolib", () => require(e.PROBE_NOLIB).probeConfirmGateSync("CONFIRM_TESTS", 5000));
  one("sync_throw", () => require(e.PROBE_THROW).probeConfirmGateSync("CONFIRM_TESTS", 5000));
  one("over", () => require(e.PROBE_SLOW).probeConfirmGateSync("CONFIRM_TESTS", 10));
  one("cause_over", () => require(e.PROBE_SLOW).probeConfirmGateWithCause("CONFIRM_TESTS", 10).cause);
  process.env.CONFIRM_TESTS = "on";
  one("mark", () => require(e.PROBE_MARK).probeConfirmGateSync("CONFIRM_TESTS", 5000));
  process.env.CONFIRM_TESTS = "off";
  delete process.env.AGENTS_MAIN_ROOT;
  one("own_off", () => m.probeConfirmGateSync("CONFIRM_TESTS", 5000));
})();
EOF
)"
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -n 1; }

case_begin "sync-probe-tokens" "hooks/lib/confirm-gate/probe.js"
check "probe.js loads" "" "$(pv LOAD)"
check "sync: CONFIRM_TESTS=off -> OFF" "OFF" "$(pv sync_off)"
check "sync: CONFIRM_TESTS=on -> ON, never ERROR" "ON" "$(pv sync_on)"
check "sync: no config-flag.js -> ERROR" "ERROR" "$(pv sync_nolib)"
check "sync: load-env throws -> ERROR" "ERROR" "$(pv sync_throw)"
check "sync: past the budget the value stays OFF (no abort in-process)" "OFF" "$(pv over)"
check "sync: past the budget the cause is over-budget" "over-budget" "$(pv cause_over)"
case_end

case_begin "async-sync-same-token" "hooks/lib/confirm-gate/probe.js"
for row in off:OFF on:ON err:ERROR; do
  name="${row%%:*}"; tok="${row#*:}"
  check "async and sync agree on $name ($tok)" "$tok|$tok" "$(pv "sync_$name")|$(pv "async_$name")"
done
case_end

case_begin "probe-uses-its-own-checkout-config-flag" "hooks/lib/confirm-gate/probe.js"
check "the probe reads the config-flag.js of the checkout probe.js lives in" "OFF" "$(pv mark)"
OUT="$(run_next_step_in "$CFG_MARK" --session vl-val 2>/dev/null || true)"
check "that tree's next-step answers from its own config-flag.js" "GATE_CONFIRM_TESTS=OFF" "$(last_line "$OUT")"
check "the probe without AGENTS_MAIN_ROOT still resolves a value" "OFF" "$(pv own_off)"
OUT="$(unset AGENTS_MAIN_ROOT; CONFIRM_TESTS=off run_next_step --session vl-val 2>/dev/null || true)"
check "next-step without AGENTS_MAIN_ROOT still emits the value" "GATE_CONFIRM_TESTS=OFF" "$(last_line "$OUT")"
case_end

case_begin "step-gate-map-table" "hooks/lib/confirm-gate/step-gate-map.js"
MAP_OUT="$(MAP_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/confirm-gate/step-gate-map.js")" \
  LINE_MOD="$(np "$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/next-step/gate-line.js")" run_with_timeout node - 2>/dev/null <<'EOF'
const e = process.env;
try {
  const m = require(e.MAP_MOD);
  const steps = ["clarify_intent", "outline", "detail", "write_tests", "write_code", "docs", "branching_complete", "research"];
  process.stdout.write("MAP=" + steps.map((s) => String(m.confirmGateForStep(s))).join(",") + "\n");
  const d = m.CONFIRM_GATE_DEFAULTS;
  process.stdout.write("DEF=" + Object.keys(d).length + ":" + Object.values(d).every((v) => v === "on") + "\n");
} catch (x) { process.stdout.write("MAP=LOAD_FAILED\n"); }
try {
  const g = require(e.LINE_MOD);
  process.stdout.write("NONGATE=[" + g.resolveGateLine("research") + "]\nTMO=" + g.NEXT_STEP_GATE_PROBE_TIMEOUT_MS + "\n");
} catch (x) { process.stdout.write("NONGATE=LOAD_FAILED\n"); }
EOF
)"
mv_() { printf '%s\n' "$MAP_OUT" | sed -n "s/^$1=//p" | head -n 1; }
check "confirmGateForStep over 7 gates + research" \
  "CONFIRM_INTENT,CONFIRM_OUTLINE,CONFIRM_DETAIL,CONFIRM_TESTS,CONFIRM_CODE,CONFIRM_DOCS,CONFIRM_WORKTREE,null" "$(mv_ MAP)"
check "CONFIRM_GATE_DEFAULTS: 7 keys, all on" "7:true" "$(mv_ DEF)"
check "resolveGateLine(non-gate) is empty" "[]" "$(mv_ NONGATE)"
check "probe timeout constant is 1500 ms" "1500" "$(mv_ TMO)"
case_end

gt_finish
