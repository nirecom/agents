#!/bin/bash
# shellcheck shell=bash
# feature-1286 module API cases: recordSkipJudgment / readSkipJudgment /
# hasValidSkipJudgment in hooks/workflow-state/skip-signal-resolver.js.
# Sourced-then-run via the dispatcher; relies on helpers.sh being sourced.
# Targets the #2460 end state: JUDGMENT_SOURCES = jev/subagent/mixed, detail keys
# sd_single_approach/sd_no_open_decision, optional 16-hex ticket in opts.

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-1: recordSkipJudgment outline → skip_judgment persisted ==="
OUT="$(resolver_eval "
  if (typeof r.recordSkipJudgment !== 'function') { console.error('recordSkipJudgment not exported'); process.exit(2); }
  r.recordSkipJudgment('rv1', 'outline', { so_c1: true, so_c2: true }, 'subagent');
  const sj = r.readSkipJudgment('rv1', 'outline');
  if (!sj) { console.log('null'); process.exit(0); }
  console.log('judgment_source=' + sj.judgment_source);
  console.log('so_c1=' + sj.conditions.so_c1);
  console.log('so_c2=' + sj.conditions.so_c2);
  console.log('all_conditions_met=' + sj.all_conditions_met);
")"
check_contains "RV-1a: judgment_source=subagent persisted" "judgment_source=subagent" "$OUT"
check_contains "RV-1b: so_c1=true persisted" "so_c1=true" "$OUT"
check_contains "RV-1c: so_c2=true persisted" "so_c2=true" "$OUT"
check_contains "RV-1d: all_conditions_met=true when both true" "all_conditions_met=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-2: recordSkipJudgment detail (new keys) → persisted ==="
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv2', 'detail', { sd_single_approach: true, sd_no_open_decision: true }, 'jev');
  const sj = r.readSkipJudgment('rv2', 'detail');
  if (!sj) { console.log('null'); process.exit(0); }
  console.log('judgment_source=' + sj.judgment_source);
  console.log('sd_single_approach=' + sj.conditions.sd_single_approach);
  console.log('sd_no_open_decision=' + sj.conditions.sd_no_open_decision);
  console.log('all_conditions_met=' + sj.all_conditions_met);
")"
check_contains "RV-2a: detail judgment_source=jev" "judgment_source=jev" "$OUT"
check_contains "RV-2b: sd_single_approach=true persisted" "sd_single_approach=true" "$OUT"
check_contains "RV-2c: sd_no_open_decision=true persisted" "sd_no_open_decision=true" "$OUT"
check_contains "RV-2d: all_conditions_met=true when both true" "all_conditions_met=true" "$OUT"

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
echo "=== RV-4: hasValidSkipJudgment true on a valid new-source record ==="
: > "$PLANS_GLOBAL_DIR/rv4-intent.md"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv4', 'outline', { so_c1: true, so_c2: true }, 'mixed');
  console.log('valid=' + r.hasValidSkipJudgment('rv4', 'outline'));
")"
check "RV-4: hasValidSkipJudgment true on valid mixed record" "valid=true" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-5: outline so_c2=false → all_conditions_met=false → invalid ==="
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv5', 'outline', { so_c1: true, so_c2: false }, 'subagent');
  const sj = r.readSkipJudgment('rv5', 'outline');
  console.log('all_conditions_met=' + (sj && sj.all_conditions_met));
  console.log('valid=' + r.hasValidSkipJudgment('rv5', 'outline'));
")"
check_contains "RV-5a: so_c2=false → all_conditions_met=false" "all_conditions_met=false" "$OUT"
check_contains "RV-5b: so_c2=false → hasValidSkipJudgment false" "valid=false" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-12: judgment_source validity — exactly JUDGMENT_SOURCES (jev/subagent/mixed) ==="
# 'orchestrator' is the retired pre-#2460 source: a record carrying it is invalid.
while IFS='|' read -r s_src s_want; do
  [ -z "$s_src" ] && continue
  : > "$PLANS_GLOBAL_DIR/rv12-${s_src}-intent.md"
  SOUT="$(resolver_eval "
    r.recordSkipJudgment('rv12-${s_src}', 'outline', { so_c1: true, so_c2: true }, '${s_src}');
    console.log('valid=' + r.hasValidSkipJudgment('rv12-${s_src}', 'outline'));
  ")"
  check_contains "RV-12 [$s_src] → valid=$s_want" "valid=$s_want" "$SOUT"
done <<'SOURCES'
jev|true
subagent|true
mixed|true
orchestrator|false
user|false
unknown|false
JEV|false
SOURCES
OUT="$(resolver_eval "console.log('sources=' + JSON.stringify(require('$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state/skip-signal-resolver/condition-schemas.js').JUDGMENT_SOURCES));")"
check_contains "RV-12h: JUDGMENT_SOURCES is exactly jev/subagent/mixed" 'sources=["jev","subagent","mixed"]' "$OUT"
OUT="$(resolver_eval "const m = require('$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state/skip-signal-resolver/condition-schemas.js'); console.log('legacy=' + ('LEGACY_JUDGMENT_SOURCE' in m || 'LEGACY_CONDITION_SCHEMAS' in m));")"
check_contains "RV-12i: the stage-4 LEGACY_* constants are gone" "legacy=false" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-14: malformed/partial skip_judgment → fail-safe (null / no throw) ==="
write_state "rv14a" '{"steps":{"outline":{"status":"pending","skip_judgment":{"judgment_source":"subagent"}}}}'
OUT="$(resolver_eval "
  const sj = r.readSkipJudgment('rv14a', 'outline');
  console.log('read=' + (sj === null ? 'null' : JSON.stringify(sj)));
  console.log('valid=' + r.hasValidSkipJudgment('rv14a', 'outline'));
")"
check_contains "RV-14a: partial skip_judgment → readSkipJudgment null" "read=null" "$OUT"
check_contains "RV-14a: partial skip_judgment → hasValidSkipJudgment false" "valid=false" "$OUT"
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
  r.recordSkipJudgment('rv15', 'outline', { so_c1: true, so_c2: true }, 'subagent');
  r.recordSkipJudgment('rv15', 'outline', { so_c1: true, so_c2: true }, 'subagent');
  const sj = r.readSkipJudgment('rv15', 'outline');
  console.log('is_array=' + Array.isArray(sj));
  console.log('src=' + (sj && sj.judgment_source));
  console.log('valid=' + r.hasValidSkipJudgment('rv15', 'outline'));
")"
check_contains "RV-15a: record twice → not an array (single object)" "is_array=false" "$OUT"
check_contains "RV-15b: record twice → judgment_source still subagent" "src=subagent" "$OUT"
check_contains "RV-15c: record twice → hasValidSkipJudgment still true" "valid=true" "$OUT"
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
while IFS='|' read -r m_sid m_target m_cond m_want; do
  [ -z "$m_sid" ] && continue
  MOUT="$(resolver_eval "
    r.recordSkipJudgment('$m_sid', '$m_target', $m_cond, 'jev');
    const sj = r.readSkipJudgment('$m_sid', '$m_target');
    console.log('acm=' + (sj && sj.all_conditions_met));
  ")"
  m_got="$(printf '%s' "$MOUT" | grep -oE 'acm=(true|false)' | head -1 | cut -d= -f2)"
  assert_eq "RV-19 [$m_sid $m_target $m_cond]→$m_want" "$m_want" "$m_got"
done <<'TABLE'
rv19a|outline|{ so_c1: false, so_c2: true }|false
rv19b|outline|{ so_c1: true, so_c2: false }|false
rv19c|outline|{ so_c1: true, so_c2: true }|true
rv19d|detail|{ sd_single_approach: false, sd_no_open_decision: true }|false
rv19e|detail|{ sd_single_approach: true, sd_no_open_decision: false }|false
rv19f|detail|{ sd_single_approach: true, sd_no_open_decision: true }|true
TABLE

# ---------------------------------------------------------------------------
# RV-20..RV-31: per-target condition-key schema validation (table-driven).
# Plants a fully-formed envelope via write_state and varies only the source and
# conditions, isolating the schema/source check from all_conditions_met.
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-20..RV-31: per-target condition-key schema and source shape (table-driven) ==="

# build_schema_fixture <sid> <target> <conditions-js-literal> <source>
build_schema_fixture() {
  local bsf_sid="$1" bsf_target="$2" bsf_cond="$3" bsf_src="$4"
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
        judgment_source:'$bsf_src',
        conditions:$bsf_cond,
        all_conditions_met:true
      };
      process.stdout.write(JSON.stringify(s));
    });
  " 2>/dev/null)"
  write_state "$bsf_sid" "$bsf_json"
  if [ "$bsf_target" = "outline" ]; then
    : > "$PLANS_GLOBAL_DIR/${bsf_sid}-intent.md"
  else
    : > "$PLANS_GLOBAL_DIR/${bsf_sid}-outline.md"
  fi
}

# Table: sid | target | conditions-json | source | expected-valid | case-label
while IFS='|' read -r h2_sid h2_target h2_cond h2_src h2_want h2_label; do
  [ -z "$h2_sid" ] && continue
  build_schema_fixture "$h2_sid" "$h2_target" "$h2_cond" "$h2_src"
  H2_OUT="$(resolver_eval "
    if (typeof r.hasValidSkipJudgment !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
    console.log(r.hasValidSkipJudgment('$h2_sid', '$h2_target') ? 'true' : 'false');
  ")"
  h2_got="$(printf '%s' "$H2_OUT" | grep -E '^(true|false)$' | head -1)"
  assert_eq "$h2_label" "$h2_want" "$h2_got"
done <<'SCHEMA_TABLE'
rv20|outline|{so_c1:true,so_c2:true}|subagent|true|RV-20: outline {so_c1,so_c2} subagent → valid=true (baseline)
rv21|outline|{so_c1:true}|subagent|false|RV-21: outline {so_c1:true} → valid=false (so_c2 missing)
rv22|outline|{"so_c1":true,"so_c2":"true"}|subagent|false|RV-22: outline so_c2:"true" → valid=false (string)
rv23|outline|{"so_c1":true,"so_c2":1}|subagent|false|RV-23: outline so_c2:1 → valid=false (number)
rv24|outline|{"so_c1":true,"so_c2":false}|subagent|false|RV-24: outline so_c2:false → valid=false (false)
rv25|outline|{"sd_single_approach":true,"sd_no_open_decision":true}|subagent|false|RV-25: outline with detail keys → valid=false (wrong-target keys)
rv26|outline|{"so_c1":true,"so_c2":true,"extra":true}|subagent|false|RV-26: outline + extra key → valid=false (excess key)
rv27|detail|{"sd_single_approach":true,"sd_no_open_decision":true}|jev|true|RV-27: detail new keys jev → valid=true (baseline)
rv28|detail|{"sd_single_approach":true}|jev|false|RV-28: detail sd_no_open_decision missing → valid=false
rv29|detail|{"sd_single_approach":true,"sd_no_open_decision":"true"}|jev|false|RV-29: detail sd_no_open_decision:"true" → valid=false (string)
rv30|detail|{"so_c1":true,"so_c2":true}|jev|false|RV-30: detail with outline keys → valid=false (step/target mismatch)
rv31|detail|{"sd_single_approach":true,"sd_no_open_decision":true,"sd_c3":true}|jev|false|RV-31: detail + sd_c3 → valid=false (excess key)
rv32|detail|{"sd_c1":true,"sd_c2":true,"sd_c3":true}|orchestrator|false|RV-32: retired form (orchestrator + sd_c1..c3) → valid=false
rv33|detail|{"sd_c1":true,"sd_c2":true,"sd_c3":true}|jev|false|RV-33: mixed shape (jev + old detail keys) → valid=false
rv34|detail|{"sd_single_approach":true,"sd_no_open_decision":true}|orchestrator|false|RV-34: mixed shape (orchestrator + new keys) → valid=false
rv35|outline|{"so_c1":true,"so_c2":true}|orchestrator|false|RV-35: outline retired source orchestrator → valid=false
rv36|detail|{"sd_single_approach":true,"sd_no_open_decision":true}|mixed|true|RV-36: detail new keys mixed → valid=true
SCHEMA_TABLE

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-37: ticket via opts — persisted only when 16-hex, never needed for validity ==="
# Prints the skip_judgment step_annotation values from the raw event stream.
annotation_values() {
  local sid="$1" step="$2"
  cat "$WORKFLOW_DIR/${sid}.json" 2>/dev/null | run_with_timeout node -e "
    let d=''; process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try{
        const s=JSON.parse(d);
        const ev=(s.events||[]).filter(e=>e.kind==='step_annotation'&&e.step==='$step'&&e.key==='skip_judgment');
        console.log('count=' + ev.length);
        for (const e of ev) console.log('value=' + JSON.stringify(e.value));
      }catch(e){console.log('PARSE_ERR');}
    });
  " 2>/dev/null || echo "READ_ERR"
}
: > "$PLANS_GLOBAL_DIR/rv37a-outline.md"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv37a', 'detail', { sd_single_approach: true, sd_no_open_decision: true }, 'jev', { ticket: '0123456789abcdef' });
  const sj = r.readSkipJudgment('rv37a', 'detail');
  console.log('ticket=' + (sj && sj.ticket));
  console.log('valid=' + r.hasValidSkipJudgment('rv37a', 'detail'));
")"
check_contains "RV-37a: a 16-hex ticket is read back by readSkipJudgment" "ticket=0123456789abcdef" "$OUT"
check_contains "RV-37a: a ticketed record is valid" "valid=true" "$OUT"
EV="$(annotation_values rv37a detail)"
check_contains "RV-37b: exactly one skip_judgment annotation event" "count=1" "$EV"
check_contains "RV-37b: the step_annotation value carries the ticket" '"ticket":"0123456789abcdef"' "$EV"

: > "$PLANS_GLOBAL_DIR/rv37c-intent.md"
OUT="$(resolver_eval "
  r.recordSkipJudgment('rv37c', 'outline', { so_c1: true, so_c2: true }, 'subagent');
  const sj = r.readSkipJudgment('rv37c', 'outline');
  console.log('has_ticket_key=' + (sj ? ('ticket' in sj) : 'NULL'));
  console.log('valid=' + r.hasValidSkipJudgment('rv37c', 'outline'));
")"
check_contains "RV-37c: a 4-arg call writes no ticket key" "has_ticket_key=false" "$OUT"
check_contains "RV-37c: a 4-arg record is still valid" "valid=true" "$OUT"
check_not_contains "RV-37c: no ticket in the event stream" '"ticket"' "$(annotation_values rv37c outline)"

# Non-16-hex tickets are never stored (wrong length, non-hex, injection text, non-string).
while IFS='|' read -r t_sid t_ticket t_label; do
  [ -z "$t_sid" ] && continue
  : > "$PLANS_GLOBAL_DIR/${t_sid}-intent.md"
  TOUT="$(resolver_eval "
    r.recordSkipJudgment('$t_sid', 'outline', { so_c1: true, so_c2: true }, 'jev', { ticket: $t_ticket });
    const sj = r.readSkipJudgment('$t_sid', 'outline');
    console.log('has_ticket_key=' + (sj ? ('ticket' in sj) : 'NULL'));
  ")"
  check_contains "RV-37d [$t_label]: ticket not stored" "has_ticket_key=false" "$TOUT"
  check_not_contains "RV-37d [$t_label]: no ticket in the event stream" '"ticket"' "$(annotation_values "$t_sid" outline)"
done <<'TICKETS'
rv37d1|'0123456789abcde'|15 hex chars
rv37d2|'0123456789abcdef0'|17 hex chars
rv37d3|'0123456789abcdeg'|non-hex char
rv37d4|'01234567;rm -rf x'|shell metacharacters
rv37d5|12345678|number
rv37d6|''|empty string
TICKETS
