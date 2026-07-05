#!/bin/bash
# shellcheck shell=bash
# feature-1286 module API cases: recordSkipJudgment / readSkipJudgment /
# hasValidSkipJudgment in hooks/lib/workflow-state/skip-signal-resolver.js.
# Sourced-then-run via the dispatcher; relies on helpers.sh being sourced.

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-1: recordSkipJudgment outline → skip_judgment persisted ==="
OUT="$(resolver_eval "
  if (typeof r.recordSkipJudgment !== 'function') { console.error('recordSkipJudgment not exported'); process.exit(2); }
  r.recordSkipJudgment('rv1', 'outline', { so_c1: true, so_c2: true }, 'orchestrator');
  const sj = r.readSkipJudgment('rv1', 'outline');
  if (!sj) { console.log('null'); process.exit(0); }
  console.log('judgment_source=' + sj.judgment_source);
  console.log('so_c1=' + sj.conditions.so_c1);
  console.log('so_c2=' + sj.conditions.so_c2);
  console.log('all_conditions_met=' + sj.all_conditions_met);
")"
check_contains "RV-1a: judgment_source=orchestrator persisted" "judgment_source=orchestrator" "$OUT"
check_contains "RV-1b: so_c1=true persisted" "so_c1=true" "$OUT"
check_contains "RV-1c: so_c2=true persisted" "so_c2=true" "$OUT"
check_contains "RV-1d: all_conditions_met=true when both true" "all_conditions_met=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-2: recordSkipJudgment detail → persisted ==="
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv2', 'detail', { sd_c1: true, sd_c2: true, sd_c3: true }, 'orchestrator');
  const sj = r.readSkipJudgment('rv2', 'detail');
  if (!sj) { console.log('null'); process.exit(0); }
  console.log('judgment_source=' + sj.judgment_source);
  console.log('sd_c1=' + sj.conditions.sd_c1);
  console.log('sd_c3=' + sj.conditions.sd_c3);
  console.log('all_conditions_met=' + sj.all_conditions_met);
")"
check_contains "RV-2a: detail judgment_source=orchestrator" "judgment_source=orchestrator" "$OUT"
check_contains "RV-2b: sd_c1=true persisted" "sd_c1=true" "$OUT"
check_contains "RV-2c: sd_c3=true persisted" "sd_c3=true" "$OUT"
check_contains "RV-2d: all_conditions_met=true when all three true" "all_conditions_met=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-3: readSkipJudgment returns null when no record ==="
OUT="$(resolver_eval "
  const sj = r.readSkipJudgment('rv3-no-record', 'outline');
  console.log(sj === null ? 'null' : JSON.stringify(sj));
")"
check "RV-3: readSkipJudgment null on missing record" "null" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-4: hasValidSkipJudgment true only when orchestrator AND all_conditions_met ==="
: > "$PLANS_GLOBAL_DIR/rv4-intent.md"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv4', 'outline', { so_c1: true, so_c2: true }, 'orchestrator');
  console.log('valid=' + r.hasValidSkipJudgment('rv4', 'outline'));
")"
check "RV-4: hasValidSkipJudgment true on valid orchestrator record" "valid=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-5: outline so_c2=false → all_conditions_met=false → invalid ==="
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv5', 'outline', { so_c1: true, so_c2: false }, 'orchestrator');
  const sj = r.readSkipJudgment('rv5', 'outline');
  console.log('all_conditions_met=' + (sj && sj.all_conditions_met));
  console.log('valid=' + r.hasValidSkipJudgment('rv5', 'outline'));
")"
check_contains "RV-5a: so_c2=false → all_conditions_met=false" "all_conditions_met=false" "$OUT"
check_contains "RV-5b: so_c2=false → hasValidSkipJudgment false" "valid=false" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-12: judgment_source validity — only 'orchestrator' counts ==="
: > "$PLANS_GLOBAL_DIR/rv12o-intent.md"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv12u', 'outline', { so_c1: true, so_c2: true }, 'user');
  console.log('user_valid=' + r.hasValidSkipJudgment('rv12u', 'outline'));
  r.recordSkipJudgment('rv12k', 'outline', { so_c1: true, so_c2: true }, 'unknown');
  console.log('unknown_valid=' + r.hasValidSkipJudgment('rv12k', 'outline'));
  r.recordSkipJudgment('rv12o', 'outline', { so_c1: true, so_c2: true }, 'orchestrator');
  console.log('orch_valid=' + r.hasValidSkipJudgment('rv12o', 'outline'));
")"
check_contains "RV-12a: judgment_source=user → invalid" "user_valid=false" "$OUT"
check_contains "RV-12b: judgment_source=unknown → invalid" "unknown_valid=false" "$OUT"
check_contains "RV-12c: judgment_source=orchestrator → valid" "orch_valid=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-14: malformed/partial skip_judgment → fail-safe (null / no throw) ==="
# Sub-case A: partial object missing conditions + all_conditions_met.
write_state "rv14a" '{"steps":{"outline":{"status":"pending","skip_judgment":{"judgment_source":"orchestrator"}}}}'
OUT="$(resolver_eval "
  const sj = r.readSkipJudgment('rv14a', 'outline');
  console.log('read=' + (sj === null ? 'null' : JSON.stringify(sj)));
  console.log('valid=' + r.hasValidSkipJudgment('rv14a', 'outline'));
")"
check_contains "RV-14a: partial skip_judgment → readSkipJudgment null" "read=null" "$OUT"
check_contains "RV-14a: partial skip_judgment → hasValidSkipJudgment false" "valid=false" "$OUT"
# Sub-case B: skip_judgment is a non-object string.
write_state "rv14b" '{"steps":{"outline":{"status":"pending","skip_judgment":"x"}}}'
OUT="$(resolver_eval "
  const sj = r.readSkipJudgment('rv14b', 'outline');
  console.log('read=' + (sj === null ? 'null' : JSON.stringify(sj)));
")"
check_contains "RV-14b: non-object skip_judgment → readSkipJudgment null (no throw)" "read=null" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-15: idempotency — record twice → single valid object, status unchanged ==="
: > "$PLANS_GLOBAL_DIR/rv15-intent.md"
write_state "rv15" "$JSON_AT_OUTLINE"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv15', 'outline', { so_c1: true, so_c2: true }, 'orchestrator');
  r.recordSkipJudgment('rv15', 'outline', { so_c1: true, so_c2: true }, 'orchestrator');
  const sj = r.readSkipJudgment('rv15', 'outline');
  console.log('is_array=' + Array.isArray(sj));
  console.log('src=' + (sj && sj.judgment_source));
  console.log('valid=' + r.hasValidSkipJudgment('rv15', 'outline'));
")"
check_contains "RV-15a: record twice → not an array (single object)" "is_array=false" "$OUT"
check_contains "RV-15b: record twice → judgment_source still orchestrator" "src=orchestrator" "$OUT"
check_contains "RV-15c: record twice → hasValidSkipJudgment still true" "valid=true" "$OUT"
# status field of the outline step must be unchanged (recordSkipJudgment must not mark skipped).
STATUS="$(read_state_field rv15 outline status)"
check "RV-15d: outline status unchanged by recordSkipJudgment" '"pending"' "$STATUS"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-19: all_conditions_met matrix (table-driven) ==="
assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$desc"
  else fail "$desc -- want [$want] got [$got]"; fi
}
# Table: sid | target | conditions-json | expected-all_conditions_met
while IFS='|' read -r m_sid m_target m_cond m_want; do
  [ -z "$m_sid" ] && continue
  MOUT="$(resolver_eval "
    r.recordSkipJudgment('$m_sid', '$m_target', $m_cond, 'orchestrator');
    const sj = r.readSkipJudgment('$m_sid', '$m_target');
    console.log('acm=' + (sj && sj.all_conditions_met));
  ")"
  m_got="$(printf '%s' "$MOUT" | grep -oE 'acm=(true|false)' | head -1 | cut -d= -f2)"
  assert_eq "RV-19 [$m_sid $m_target $m_cond]→$m_want" "$m_want" "$m_got"
done <<'TABLE'
rv19a|outline|{ so_c1: false, so_c2: true }|false
rv19b|outline|{ so_c1: true, so_c2: false }|false
rv19c|outline|{ so_c1: true, so_c2: true }|true
rv19d|detail|{ sd_c1: false, sd_c2: true, sd_c3: true }|false
rv19e|detail|{ sd_c1: true, sd_c2: true, sd_c3: false }|false
rv19f|detail|{ sd_c1: true, sd_c2: true, sd_c3: true }|true
TABLE

# ---------------------------------------------------------------------------
# RV-20..RV-31: hardening #2 (plan RV-20..RV-31) — hasValidSkipJudgment
# per-target condition-key schema validation (table-driven).
#
# Strategy: plant a FULLY-FORMED envelope via write_state (not recordSkipJudgment)
# with all_conditions_met:true, judgment_source:"orchestrator", valid recorded_at —
# and vary ONLY the `conditions` object per case. This isolates the schema check
# from the all_conditions_met check already tested in RV-1..RV-5/RV-19.
# Mirror the envelope shape used in next-step.sh RV-REC-1.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-20..RV-31: hardening #2 — per-target condition-key schema (table-driven) ==="

# assert_eq already defined above.
# Helper: build a fully-formed skip_judgment envelope for a given target step,
# piping the appropriate base JSON via stdin (avoids env-var quoting issues).
# Usage: build_schema_fixture <sid> <target> <conditions-js-literal>
build_schema_fixture() {
  local bsf_sid="$1" bsf_target="$2" bsf_cond="$3"
  # Choose base fixture with the target step present.
  local bsf_base
  if [ "$bsf_target" = "outline" ]; then bsf_base="$JSON_AT_OUTLINE"
  else bsf_base="$JSON_AT_DETAIL"; fi
  local bsf_json
  bsf_json="$(printf '%s' "$bsf_base" | run_with_timeout node -e "
    let d=''; process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      const s=JSON.parse(d);
      s.steps['$bsf_target'].skip_judgment={
        recorded_at:'2099-01-01T00:00:00.000Z',
        judgment_source:'orchestrator',
        conditions:$bsf_cond,
        all_conditions_met:true
      };
      process.stdout.write(JSON.stringify(s));
    });
  " 2>/dev/null)"
  write_state "$bsf_sid" "$bsf_json"
  # Create artifact so hasValidSkipJudgment's stale-guard can resolve it.
  if [ "$bsf_target" = "outline" ]; then
    : > "$PLANS_GLOBAL_DIR/${bsf_sid}-intent.md"
  else
    : > "$PLANS_GLOBAL_DIR/${bsf_sid}-outline.md"
  fi
}

# Table: rv_sid | target | conditions-json | expected-valid (true|false) | case-label
while IFS='|' read -r h2_sid h2_target h2_cond h2_want h2_label; do
  [ -z "$h2_sid" ] && continue
  build_schema_fixture "$h2_sid" "$h2_target" "$h2_cond"
  H2_OUT="$(resolver_eval "
    if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
    const result = r.hasValidSkipJudgment('$h2_sid', '$h2_target');
    console.log(result ? 'true' : 'false');
  ")"
  h2_got="$(printf '%s' "$H2_OUT" | grep -E '^(true|false)$' | head -1)"
  assert_eq "$h2_label" "$h2_want" "$h2_got"
done <<'SCHEMA_TABLE'
rv20|outline|{so_c1:true,so_c2:true}|true|RV-20: outline {so_c1:true,so_c2:true} → valid=true (baseline)
rv21|outline|{so_c1:true}|false|RV-21: outline {so_c1:true} → valid=false (so_c2 missing)
rv22|outline|{"so_c1":true,"so_c2":"true"}|false|RV-22: outline {so_c1:true,so_c2:"true"} → valid=false (string non-boolean-true)
rv23|outline|{"so_c1":true,"so_c2":1}|false|RV-23: outline {so_c1:true,so_c2:1} → valid=false (number)
rv24|outline|{"so_c1":true,"so_c2":false}|false|RV-24: outline {so_c1:true,so_c2:false} → valid=false (false)
rv25|outline|{"sd_c1":true,"sd_c2":true,"sd_c3":true}|false|RV-25: outline {sd_c1:*} → valid=false (wrong-target keys)
rv26|outline|{"so_c1":true,"so_c2":true,"extra":true}|false|RV-26: outline {so_c1:true,so_c2:true,extra:true} → valid=false (excess key)
rv27|detail|{"sd_c1":true,"sd_c2":true,"sd_c3":true}|true|RV-27: detail {sd_c1:true,sd_c2:true,sd_c3:true} → valid=true (baseline)
rv28|detail|{"sd_c1":true,"sd_c2":true}|false|RV-28: detail {sd_c1:true,sd_c2:true} → valid=false (sd_c3 missing)
rv29|detail|{"sd_c1":true,"sd_c2":true,"sd_c3":"true"}|false|RV-29: detail {sd_c1:true,sd_c2:true,sd_c3:"true"} → valid=false (string)
rv30|detail|{"so_c1":true,"so_c2":true}|false|RV-30: detail {so_c1:*,so_c2:*} → valid=false (step/target mismatch)
rv31|detail|{"sd_c1":true,"sd_c2":true,"sd_c3":true,"sd_c4":true}|false|RV-31: detail {sd_c1..sd_c4} → valid=false (excess key)
SCHEMA_TABLE
