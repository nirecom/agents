# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/a-contract.sh
# Tests: hooks/lib/worker-outcome-contract.js, hooks/lib/plans-artifact-registry.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, contract, registry, tl1, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# The outcome file is the only channel run_tests completes from, so its name, shape
# and rejection behaviour are pinned here before any hook case relies on them.

f2544_a_names() {
  local stem fn suffix
  for stem in "$F2544_T-3" "$F2544_T"; do
    while IFS='|' read -r fn suffix; do
      f2544_eq "A/name $fn($stem)" "$(f2544_probe call "$F2544_M_CONTRACT" "$fn" "[\"$stem\"]")" "$stem$suffix"
    done <<'TABLE'
outcomeFileName|.outcome.json
ingestedMarkerName|.ingested
TABLE
  done
  f2544_eq "A/schema version is 1" "$(f2544_probe value "$F2544_M_CONTRACT" SCHEMA_VERSION)" "1"
  f2544_eq "A/status vocabulary is the dispatcher's" "$(f2544_probe value "$F2544_M_CONTRACT" OUTCOME_STATUSES)" \
    '["pass","fail","timeout","runner-error"]'
  f2544_eq "A/digest is sha256 hex of the payload bytes" "$(f2544_probe digest abc)" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}

f2544_a_round_trip() {
  local sid="f2544-a-rt" stem="$F2544_T-1" long
  f2544_probe payload "$sid" "$stem" "$F2544_ROOT_N"
  f2544_eq "A/round trip: a built outcome validates and keeps its stem" \
    "$(f2544_probe validate "$sid" "$stem" '{}')" "ok:$stem"
  f2544_eq "A/round trip: every status word of the dispatcher validates (timeout)" \
    "$(f2544_probe validate "$sid" "$stem" '{"status":"timeout","exit_code":-1}')" "ok:$stem"
  f2544_eq "A/round trip: runner-error validates" \
    "$(f2544_probe validate "$sid" "$stem" '{"status":"runner-error","exit_code":-1}')" "ok:$stem"
  f2544_eq "A/round trip: an empty cwd validates (non-string payload cwd on a refusal)" \
    "$(f2544_probe validate "$sid" "$stem" '{"cwd":""}')" "ok:$stem"
  f2544_eq "A/round trip: a null run_contract validates" \
    "$(f2544_probe validate "$sid" "$stem" '{"worker_result":{"run_contract":null}}')" "ok:$stem"
  long="$(printf 'x%.0s' $(seq 1 296))"
  f2544_eq "A/round trip: a 296-character summary validates" \
    "$(f2544_probe validate "$sid" "$stem" "{\"worker_result\":{\"summary\":\"$long\"}}")" "ok:$stem"
}

f2544_a_rejections() {
  local sid="f2544-a-rej" stem="$F2544_T-1" name over drop long
  f2544_probe payload "$sid" "$stem" "$F2544_ROOT_N"
  while IFS='|' read -r name over drop; do
    f2544_eq "A/reject $name" "$(f2544_probe validate "$sid" "$stem" "$over" "$drop")" "reject:with-reason"
  done <<'TABLE'
unknown-schema-version|{"schema_version":2}|
missing-schema-version|{}|schema_version
missing-worker|{}|worker
non-string-stem|{"stem":7}|
empty-session-id|{"session_id":""}|
missing-session-id|{}|session_id
digest-not-hex|{"payload_sha256":"not-a-digest"}|
digest-too-short|{"payload_sha256":"abc123"}|
missing-cwd|{}|cwd
non-string-cwd|{"cwd":7}|
status-outside-vocabulary|{"status":"green"}|
exit-code-as-string|{"exit_code":"0"}|
worker-result-null|{"worker_result":null}|
missing-worker-result|{}|worker_result
failing-tests-not-a-list|{"worker_result":{"failing_tests":"tests/a.sh"}}|
failing-tests-holds-non-string|{"worker_result":{"failing_tests":[7]}}|
summary-not-a-string|{"worker_result":{"summary":7}}|
TABLE
  long="$(printf 'x%.0s' $(seq 1 297))"
  f2544_eq "A/reject summary longer than 296 characters" \
    "$(f2544_probe validate "$sid" "$stem" "{\"worker_result\":{\"summary\":\"$long\"}}")" "reject:with-reason"
  local raw
  for raw in 'null' '[]' '"text"' '7' '{}'; do
    f2544_eq "A/reject non-outcome input $raw without throwing" \
      "$(f2544_probe validate --raw "$raw")" "reject:with-reason"
  done
}

f2544_a_registry() {
  local sid="f2544areg" suffix kind kinds=""
  f2544_eq "A/registry control: a payload name is still the payload kind" \
    "$(f2544_probe kind "$sid-$F2544_T-1.json")" "control:worker-payload"
  f2544_eq "A/registry control: the dispatch marker kind is unchanged" \
    "$(f2544_probe kind "$sid-$F2544_T-1.dispatched")" "control:worker-dispatched"
  for suffix in .outcome.json .ingested; do
    for kind in "$(f2544_probe kind "$sid-$F2544_T-1$suffix")" "$(f2544_probe kind "$sid-$F2544_T$suffix")"; do
      if [[ "$kind" == control:* && "$kind" != "control:worker-payload" && "$kind" != "control:worker-dispatched" ]]; then
        pass "A/registry: $suffix is one control kind of its own ($kind)"
      else
        fail "A/registry: $suffix is one control kind of its own" "got [$kind]"
      fi
    done
    kinds="$kinds $(f2544_probe kind "$sid-$F2544_T-1$suffix")"
  done
  # shellcheck disable=SC2086
  f2544_eq "A/registry: the two new kinds are distinct" \
    "$(printf '%s\n' $kinds | sort -u | grep -c '^control:')" "2"
  f2544_eq "A/registry: an outcome draft-like name stays unregistered" \
    "$(f2544_probe kind "$sid-$F2544_T-1.outcome.txt")" "none"
}

# A forged outcome dropped in the plans dir must not be carried into the control dir.
f2544_a_migration() {
  local sid="f2544amig" suffix legacy got
  f2544_probe seed "$sid" workflow_init complete
  for suffix in .outcome.json .ingested; do
    printf 'fixture%s\n' "$suffix" > "$WORKFLOW_PLANS_DIR/$sid-$F2544_T-1$suffix"
  done
  got="$(f2544_probe call hooks/workflow-state/state-io/control-dir.js controlPath "[\"$sid\",\"$F2544_T-1.outcome.json\",{\"forWrite\":true}]")"
  f2544_ne "A/migration: resolving a control path does not throw on the new names" "${got%%:*}" "THREW"
  for suffix in .outcome.json .ingested; do
    legacy="$WORKFLOW_PLANS_DIR/$sid-$F2544_T-1$suffix"
    f2544_eq "A/migration: a plans-dir $suffix is left where it is" "$([[ -f "$legacy" ]] && echo yes || echo no)" "yes"
    f2544_eq "A/migration: and no $suffix appears in the control dir" \
      "$(f2544_probe exists "$sid" "$F2544_T-1$suffix")" "no"
  done
}

case_begin "outcome-file-names-and-constants" "hooks/lib/worker-outcome-contract.js"
f2544_a_names
case_end

case_begin "outcome-build-validate-round-trip" "hooks/lib/worker-outcome-contract.js"
f2544_a_round_trip
case_end

case_begin "outcome-validation-rejects-malformed-shapes" "hooks/lib/worker-outcome-contract.js"
f2544_a_rejections
case_end

case_begin "registry-new-control-kinds-do-not-overlap-payload" "hooks/lib/plans-artifact-registry.js"
f2544_a_registry
case_end

case_begin "control-dir-migration-skips-new-kinds" "hooks/lib/plans-artifact-registry.js"
f2544_a_migration
case_end
