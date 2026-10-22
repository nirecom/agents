#!/usr/bin/env bash
# Tests: hooks/lib/jev/registry.js
# Tags: TL2, hooks, jev, registry, validate-registry, threshold-by-answer, short-circuit, required-sections, recording-owner, scope:issue-specific, pwsh-not-required
# Fragment of tests/hooks/feature-2460-jev-broker.sh, sourced by it after _lib.sh (not
# standalone): the per-point registry schema (#2460 stage 2). validateRegistry rejects every
# malformed calibration and retired single-value shape, the shipped defaults are pinned per
# point, and recordingOwner picks the hook only for a shadow point the hook can observe.

RP_N="$(np "$(dirname "${BASH_SOURCE[0]}")/registry-probe.js")"
# rp <cmd> [args...]: one registry probe process from the fixture cwd.
rp() {
  ( cd "$FX/cwd" || exit 97
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE bash "$RWT" 30 node "$RP_N" "$REPO_N" "$@" 2>> "$ERR_ALL" < /dev/null )
}

echo "=== registry schema (validateRegistry / recordingOwner) ==="
fx_new e-registry
EXPORTS="$(rp exports)"
if [ "$EXPORTS" != "validateRegistry=true,recordingOwner=true" ]; then
  fail "MODULE_MISSING: hooks/lib/jev/registry.js validateRegistry/recordingOwner — not implemented yet (expected red until stage 2 lands)" "$EXPORTS"
  return 0
fi

case_begin "e-registry-shipped-entries-valid" "hooks/lib/jev/registry.js"
for p in complexity-judge outline-skip detail-skip; do
  check "$p: the shipped entry passes validateRegistry" "accept" "$(rp v "$p")"
  check "$p: registryEntry returns it" "object" "$(rp entry "\"$p\"")"
done
case_end

case_begin "e-registry-threshold-values" "hooks/lib/jev/registry.js"
for v in 0.5 0.9 1; do
  check "threshold true=$v accepted" "accept" "$(rp v complexity-judge confidence_threshold_by_answer.true "$v")"
  check "threshold false=$v accepted" "accept" "$(rp v complexity-judge confidence_threshold_by_answer.false "$v")"
done
for v in 0.4 1.5 __inf__ __nan__ '"0.7"' true; do
  check "threshold true=$v rejected" "reject" "$(rp v complexity-judge confidence_threshold_by_answer.true "$v")"
  check "threshold false=$v rejected" "reject" "$(rp v outline-skip confidence_threshold_by_answer.false "$v")"
done
# #2677: null means "never adopted" in one direction; null in both directions is rejected.
check "threshold false=null (true numeric) accepted" "accept" "$(rp v outline-skip confidence_threshold_by_answer.false null)"
check "threshold true=null (false numeric) accepted" "accept" "$(rp v outline-skip confidence_threshold_by_answer.true null)"
check "threshold true=null beside the shipped complexity false=null rejected" "reject" \
  "$(rp v complexity-judge confidence_threshold_by_answer.true null)"
case_end

case_begin "e-registry-threshold-shape" "hooks/lib/jev/registry.js"
check "threshold object missing \"true\" rejected" "reject" \
  "$(rp v detail-skip confidence_threshold_by_answer.true __delete__)"
check "threshold object missing \"false\" rejected" "reject" \
  "$(rp v detail-skip confidence_threshold_by_answer.false __delete__)"
check "threshold object with an extra key rejected" "reject" \
  "$(rp v detail-skip confidence_threshold_by_answer.maybe 0.8)"
check "a single number (retired confidence_threshold shape) rejected" "reject" \
  "$(rp v complexity-judge confidence_threshold_by_answer 0.7)"
check "an array threshold rejected" "reject" "$(rp v complexity-judge confidence_threshold_by_answer '[0.7,0.7]')"
check "threshold key missing rejected" "reject" "$(rp v complexity-judge confidence_threshold_by_answer __delete__)"
case_end

case_begin "e-registry-short-circuit-answer" "hooks/lib/jev/registry.js"
check "short_circuit_answer missing rejected (null must be explicit)" "reject" \
  "$(rp v complexity-judge short_circuit_answer __delete__)"
for v in true false null; do
  check "short_circuit_answer=$v accepted" "accept" "$(rp v outline-skip short_circuit_answer "$v")"
done
for v in '"false"' 0 1 '"null"' '{}'; do
  check "short_circuit_answer=$v rejected" "reject" "$(rp v outline-skip short_circuit_answer "$v")"
done
case_end

case_begin "e-registry-required-sections" "hooks/lib/jev/registry.js"
check "a stage missing from required_sections_by_stage rejected" "reject" \
  "$(rp v complexity-judge required_sections_by_stage.write-code __delete__)"
check "an extra stage not in stages rejected" "reject" \
  "$(rp v outline-skip required_sections_by_stage.detail '["intent","outline","issue body"]')"
check "an empty array rejected" "reject" "$(rp v outline-skip required_sections_by_stage.outline '[]')"
check "a stage without intent rejected" "reject" \
  "$(rp v outline-skip required_sections_by_stage.outline '["issue body"]')"
check "a stage without issue body rejected" "reject" \
  "$(rp v outline-skip required_sections_by_stage.outline '["intent"]')"
check "a section outside STAGE_SOURCE_SECTIONS (detail at complexity) rejected" "reject" \
  "$(rp v complexity-judge required_sections_by_stage.complexity '["intent","detail","issue body"]')"
check "an unknown section name rejected" "reject" \
  "$(rp v detail-skip required_sections_by_stage.outline '["intent","outline","issue body","rm -rf /"]')"
check "a single array (retired required_sections shape) rejected" "reject" \
  "$(rp v complexity-judge required_sections_by_stage '["intent","issue body"]')"
check "required_sections_by_stage replaced by the retired required_sections key rejected" "reject" \
  "$(rp v complexity-judge required_sections_by_stage __delete__ required_sections '["intent","issue body"]')"
case_end

case_begin "e-registry-enums-and-required-keys" "hooks/lib/jev/registry.js"
check "mode outside production|shadow rejected" "reject" "$(rp v complexity-judge mode '"live"')"
check "mode production accepted" "accept" "$(rp v complexity-judge mode '"production"')"
check "mode shadow accepted" "accept" "$(rp v complexity-judge mode '"shadow"')"
check "an unknown stage name rejected" "reject" \
  "$(rp v outline-skip stages '["complexity","outline","write_code"]' required_sections_by_stage.write_code '["intent","issue body"]')"
for k in adapter backup_subagent fallback stages mode; do
  check "missing $k rejected" "reject" "$(rp v detail-skip "$k" __delete__)"
done
case_end

case_begin "e-registry-defaults-complexity" "hooks/lib/jev/registry.js"
D="$(rp defaults complexity-judge)"
check "complexity-judge defaults" \
  '{"adapter":"jev-complexity-adapter.js","adapter_exists":true,"target":"<absent>","normalizer":"normalize-judge-signals","threshold":{"true":0.7,"false":null},"short_circuit_answer":true,"backup_subagent":"complexity-judge","subagent_type":"complexity-judge","fallback":"S0-undecidable","stages":["complexity","outline","detail","write-tests","write-code"],"required":{"complexity":["intent","issue body"],"outline":["intent","issue body"],"detail":["intent","outline","issue body"],"write-tests":["issue body"],"write-code":["issue body"]},"plan_sections":{"write-tests":["detail","outline","intent"],"write-code":["detail","outline","intent"]},"retired":[]}' \
  "$D"
case_end

case_begin "e-registry-defaults-skip" "hooks/lib/jev/registry.js"
check "outline-skip defaults" \
  '{"adapter":"jev-skip-adapter.js","adapter_exists":true,"target":"outline","normalizer":"<absent>","threshold":{"true":0.9,"false":0.7},"short_circuit_answer":false,"backup_subagent":"plan-skip-judge","subagent_type":"<absent>","fallback":"run","stages":["complexity","outline"],"required":{"complexity":["intent","issue body"],"outline":["intent","issue body"]},"plan_sections":"<absent>","retired":[]}' \
  "$(rp defaults outline-skip)"
check "detail-skip defaults" \
  '{"adapter":"jev-skip-adapter.js","adapter_exists":true,"target":"detail","normalizer":"<absent>","threshold":{"true":0.9,"false":0.7},"short_circuit_answer":false,"backup_subagent":"plan-skip-judge","subagent_type":"<absent>","fallback":"run","stages":["outline"],"required":{"outline":["intent","outline","issue body"]},"plan_sections":"<absent>","retired":[]}' \
  "$(rp defaults detail-skip)"
for p in outline-skip detail-skip; do
  check "$p: the retired symmetric 0.9 gate is gone (false direction is not 0.9)" "no" \
    "$(rp defaults "$p" | grep -Fq '"threshold":{"true":0.9,"false":0.9}' && echo yes || echo no)"
done
for p in complexity-judge outline-skip detail-skip; do
  check "$p: every stage requires issue body" "yes" \
    "$(rp defaults "$p" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s).required;process.stdout.write(Object.values(r).length>0&&Object.values(r).every(a=>a.includes("issue body"))?"yes":"no")})' 2>/dev/null)"
done
MODES="$(for p in complexity-judge outline-skip detail-skip; do rp mode "$p"; echo; done | sort -u | tr '\n' ',')"
case "$MODES" in production,|shadow,) MODES_OK=yes ;; *) MODES_OK="no:$MODES" ;; esac
check "all three points share one mode (production or shadow)" "yes" "$MODES_OK"
case_end

# The shipped mode is shadow in stages 2-5 and production from stage 6 (detail plan L288/L352).
# This pins the end state, so it stays red until the stage-6 registry switch lands.
case_begin "e-registry-shipped-mode-production" "hooks/lib/jev/registry.js"
for p in complexity-judge outline-skip detail-skip; do
  check "$p: shipped mode is production (stage 6 switch)" "production" "$(rp mode "$p")"
done
check "complexity-judge as shipped: CLI records (production + subagent_type)" "cli" \
  "$(rp owner-of complexity-judge)"
case_end

case_begin "e-registry-recording-owner" "hooks/lib/jev/registry.js"
check "shadow + subagent_type: hook" "hook" "$(rp owner '{"mode":"shadow","subagent_type":"complexity-judge"}')"
check "shadow without subagent_type: cli" "cli" "$(rp owner '{"mode":"shadow"}')"
check "production + subagent_type: cli" "cli" "$(rp owner '{"mode":"production","subagent_type":"complexity-judge"}')"
check "production without subagent_type: cli" "cli" "$(rp owner '{"mode":"production"}')"
case_end
