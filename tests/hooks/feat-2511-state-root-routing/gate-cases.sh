# commit-push gate and project-cache cases (R20, R20b, R23) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

# gate_val <json> — the WORKFLOW_STATE_DIR value in a resolveGateEnv dump.
gate_val() {
  local m
  m="$(grep -o '"WORKFLOW_STATE_DIR":"[^"]*"' <<<"$1" || true)"
  m="${m#*:\"}"
  printf '%s' "${m%\"}"
}

c_r20_gate_routes_session() {
  local script_checkout_root old fresh out
  new_home r20
  script_checkout_root="$(np "$T/r20-script-checkout-root")"
  mkdir -p "$script_checkout_root"
  : >"$script_checkout_root/.env"
  old="$(sid_of 2001)"
  fresh="$(sid_of 2002)"
  probe_seed "$LEG" "$old"
  out="$(dprobe gateenv "$script_checkout_root" "$old")"
  eq "R20 the gate child gets the legacy dir for a legacy session" "$(gate_val "$out")" "$LEG"
  out="$(dprobe gateenv "$script_checkout_root" "$fresh")"
  eq "R20 the gate child gets the new dir for a fresh session" "$(gate_val "$out")" "$NEW"
  eq "R20 the retired key is no longer passed to the gate child" "$(grep -c "\"$OLD_TOKEN\"" <<<"$out" || true)" "0"
}

c_r20b_gate_ignores_parent_env() {
  local script_checkout_root sid other cfg out
  new_home r20b
  script_checkout_root="$(np "$T/r20b-script-checkout-root")"
  mkdir -p "$script_checkout_root"
  : >"$script_checkout_root/.env"
  sid="$(sid_of 2003)"
  other="$(np "$T/pins/r20b-other")"
  cfg="$(np "$T/pins/r20b-cfg")"
  mkdir -p "$other" "$cfg"
  probe_seed "$LEG" "$sid"
  out="$(pprobe "$other" gateenv "$script_checkout_root" "$sid")"
  eq "R20b a parent-env pin is ignored; the home-routed dir is passed" "$(gate_val "$out")" "$LEG"
  out="$(pprobe "$other" gateenv "$script_checkout_root" "$(sid_of 2004)")"
  eq "R20b a parent-env pin is ignored for a fresh session too" "$(gate_val "$out")" "$NEW"
  printf 'WORKFLOW_STATE_DIR=%s\n' "$cfg" >"$script_checkout_root/.env"
  out="$(pprobe "$other" gateenv "$script_checkout_root" "$sid")"
  eq "R20b an .env value is passed as-is" "$(gate_val "$out")" "$cfg"
}

c_r23_project_cache() {
  local stub row out
  new_home r23
  stub="$T/r23-bin"
  mkdir -p "$stub" "$NEW/cache" "$LEG/cache"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$stub/gh"
  chmod +x "$stub/gh"
  row() { printf 'acme/demo\tacme\t7\t%s\t\t\t\t\t\t\n' "$1"; }
  row PVT_new >"$NEW/cache/project-resolve.tsv"
  row PVT_old >"$LEG/cache/project-resolve.tsv"
  out="$(cd "$T/cwd" && PATH="$stub:$PATH" BOARD_CARD_REPO_OVERRIDE=acme/demo run_with_timeout 30 \
    env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    bash -c '. "$1"; resolve_project_for_repo >/dev/null 2>&1; printf "%s" "$RESOLVED_PROJECT_ID"' _ \
    "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/resolve-project.sh" 2>/dev/null || true)"
  eq "R23 resolve-project reads the new-root cache/" "$out" "PVT_new"
  eq "R23 run-issue-setup no longer defaults the cache to the legacy dir" \
    "$(grep -c 'projects/workflow' "$SCRIPT_CHECKOUT_ROOT/skills/issue-setup/scripts/run-issue-setup.sh" || true)" "0"
  eq "R23 resolve-project no longer defaults the cache to the legacy dir" \
    "$(grep -c 'projects/workflow' "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/resolve-project.sh" || true)" "0"
}
