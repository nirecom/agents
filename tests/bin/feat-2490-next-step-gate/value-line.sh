#!/usr/bin/env bash
# tests/bin/feat-2490-next-step-gate/value-line.sh
# Tests: bin/workflow/lib/next-step/gate-line.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/parse-next-step-output.js, hooks/lib/confirm-gate/probe.js, hooks/lib/confirm-gate/step-gate-map.js
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
  ns --session "$sid"
  check "$step: ACTION=invoke" "invoke" "$(val ACTION)"
  check "$step: NEXT_SKILL is the step skill" "$(skill_of "$step")" "$(val NEXT_SKILL)"
  check "$step: exactly one GATE_CONFIRM_ line" 1 "$(count_re "$OUT" '^GATE_CONFIRM_')"
  check "$step: the value line is the last line" "GATE_$(gate_key_of "$step")=ON" "$(last_line "$OUT")"
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
export CONFIRM_TESTS=on; ns --session vl-val
check "env on beats .env off -> ON" "GATE_CONFIRM_TESTS=ON" "$(last_line "$OUT")"
: > "$CFG/.env"
case_end

CFG_NOGCV="$GT_BASE/cfg-nogcv"; mk_tree "$CFG_NOGCV"; rm -f "$CFG_NOGCV/bin/get-config-var"
CFG_E4="$GT_BASE/cfg-e4"; mk_tree "$CFG_E4"; printf '#!/usr/bin/env bash\nexit 4\n' > "$CFG_E4/bin/get-config-var"
CFG_NOCO="$GT_BASE/cfg-noco"; mk_tree "$CFG_NOCO"; rm -f "$CFG_NOCO/bin/confirm-off" "$CFG_NOCO/bin/get-config-var"
CFG_SLOW="$GT_BASE/cfg-slow"; mk_tree "$CFG_SLOW"; printf '#!/usr/bin/env bash\nsleep 5\necho OFF\n' > "$CFG_SLOW/bin/confirm-off"
probe_of() { np "$1/hooks/lib/confirm-gate/probe.js"; }

case_begin "broken-checkout-error-variants" "hooks/lib/confirm-gate/probe.js"
for row in "no get-config-var|$CFG_NOGCV" "get-config-var exits 4|$CFG_E4" "no confirm-off|$CFG_NOCO"; do
  OUT="$(run_next_step_in "${row#*|}" --session vl-val 2>/dev/null || true)"
  check "${row%%|*} -> ERROR" "GATE_CONFIRM_TESTS=ERROR" "$(last_line "$OUT")"
done
case_end

# One node drives both probe flavours over the same inputs (CPR-ORTH); a broken row loads
# the probe of its own tree, because the probe runs the confirm-off of the checkout it
# lives in. Each row prints name=token.
PROBE_OUT="$(PROBE_MOD="$(probe_of "$SCRIPT_CHECKOUT_ROOT")" PROBE_E4="$(probe_of "$CFG_E4")" \
  PROBE_SLOW="$(probe_of "$CFG_SLOW")" PROBE_NOGCV="$(probe_of "$CFG_NOGCV")" \
  PROBE_NOCO="$(probe_of "$CFG_NOCO")" run_with_timeout node - 2>/dev/null <<'EOF'
const e = process.env;
const out = (k, v) => process.stdout.write(k + "=" + v + "\n");
(async () => {
  let m;
  try { m = require(e.PROBE_MOD); } catch (err) { out("LOAD", "FAILED"); return; }
  const rows = [["off", e.PROBE_MOD, "off", 5000], ["on", e.PROBE_MOD, "on", 5000], ["err", e.PROBE_E4, "on", 5000]];
  for (const [name, mod, v, t] of rows) {
    process.env.CONFIRM_TESTS = v;
    let s, a;
    try { s = require(mod).probeConfirmGateSync("CONFIRM_TESTS", t); } catch (x) { s = "THREW"; }
    try { a = await require(mod).probeConfirmGate("CONFIRM_TESTS", t); } catch (x) { a = "THREW"; }
    out("sync_" + name, s); out("async_" + name, a);
  }
  process.env.CONFIRM_TESTS = "off";
  const one = (k, f) => { try { out(k, f()); } catch (x) { out(k, "THREW"); } };
  one("sync_timeout", () => require(e.PROBE_SLOW).probeConfirmGateSync("CONFIRM_TESTS", 300));
  one("sync_nogcv", () => require(e.PROBE_NOGCV).probeConfirmGateSync("CONFIRM_TESTS", 5000));
  one("sync_noco", () => require(e.PROBE_NOCO).probeConfirmGateSync("CONFIRM_TESTS", 5000));
  delete process.env.AGENTS_MAIN_ROOT;
  one("own", () => String(m.buildProbeInvocation("CONFIRM_TESTS", 5000).args[0]).toLowerCase());
  one("own_off", () => m.probeConfirmGateSync("CONFIRM_TESTS", 5000));
})();
EOF
)"
pv() { printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | head -n 1; }

case_begin "sync-probe-exit-codes" "hooks/lib/confirm-gate/probe.js"
check "probe.js loads" "" "$(pv LOAD)"
check "sync: CONFIRM_TESTS=off -> OFF" "OFF" "$(pv sync_off)"
check "sync: exit 1 + stdout ON -> ON, never ERROR" "ON" "$(pv sync_on)"
check "sync: confirm-off exit 2 -> ERROR" "ERROR" "$(pv sync_err)"
check "sync: unresponsive confirm-off past the timeout -> ERROR" "ERROR" "$(pv sync_timeout)"
check "sync: no get-config-var -> ERROR" "ERROR" "$(pv sync_nogcv)"
check "sync: no confirm-off -> ERROR" "ERROR" "$(pv sync_noco)"
case_end

case_begin "async-sync-same-token" "hooks/lib/confirm-gate/probe.js"
for row in off:OFF on:ON err:ERROR; do
  name="${row%%:*}"; tok="${row#*:}"
  check "async and sync agree on $name ($tok)" "$tok|$tok" "$(pv "sync_$name")|$(pv "async_$name")"
done
case_end

case_begin "probe-runs-its-own-checkout-confirm-off" "hooks/lib/confirm-gate/probe.js"
check "the probe invokes the confirm-off of the checkout probe.js lives in" \
  "$(np "$SCRIPT_CHECKOUT_ROOT" | tr 'A-Z' 'a-z')/bin/confirm-off" "$(pv own)"
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
