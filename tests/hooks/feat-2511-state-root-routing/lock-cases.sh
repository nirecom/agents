# Lock re-acquire cases (R22, R22b, R22c, R22d) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.
# Writer A is the test itself: a foreign-host lock file is never stale by pid, so
# it holds until removed. B is a background probe that must wait on it.

fake_lock() {
  mkdir -p "$(dirname "$1")"
  printf '{"pid":1,"host":"other-host.example","at":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$1"
}

# bg_probe <outfile> <probe args...> — start B in the default env; sets BPID.
bg_probe() {
  local o="$1"
  shift
  (cd "$T/cwd" && run_with_timeout 20 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" HOME="$H" USERPROFILE="$H" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$NOTX" node "$PROBE" "$A" "$@" >"$o" 2>"$o.err") &
  BPID=$!
}

running() { kill -0 "$1" 2>/dev/null && echo running; }

# count_in <pattern> <file> — match count; 0 when the file does not exist.
count_in() {
  [[ -f "$2" ]] || { echo 0; return; }
  grep -c "$1" "$2" || true
}

# r22_scenario <label> <mode> <expect-fragment> [extra probe arg] — the move-under-lock race.
r22_scenario() {
  local label="$1" mode="$2" want="$3" extra="${4:-}" sid o
  new_home "r22-$label"
  sid="$(sid_of "22$RANDOM")"
  o="$T/r22-$label.out"
  probe_seed "$LEG" "$sid"
  fake_lock "$LEG/$sid.json.lock"
  bg_probe "$o" "$mode" "$sid" ${extra:+"$extra"}
  sleep 0.8
  # Premise: B is still blocked on A's legacy lock, so a later failure is not a startup race.
  eq "R22 $label premise: B is waiting on the legacy lock" "$(running "$BPID")" "running"
  fake_lock "$NEW/$sid.json.lock"
  probe_seed "$NEW" "$sid" '{"last_pushed_sha":"from-a"}'
  rm -f "$LEG/$sid.json" "$LEG/$sid.json.lock"
  sleep 1.0
  eq "R22 $label: B now waits on the new-root lock" "$(running "$BPID")" "running"
  eq "R22 $label: the new json is untouched while A holds the new lock" \
    "$(grep -c "$want" "$NEW/$sid.json" || true)" "0"
  rm -f "$NEW/$sid.json.lock"
  wait "$BPID" || true
  eq "R22 $label: B finished cleanly" "$(cat "$o")" "done"
  eq "R22 $label: B's change landed in the new-root json" "$(grep -c "$want" "$NEW/$sid.json" || true)" "1"
  # writeState is a whole-record write whose read (readState) ran before any lock was
  # taken, so only the lock-scoped read-modify-write modes can keep A's value.
  if [[ "$mode" != writestate ]]; then
    eq "R22 $label: B's read was the new-root content (A's value kept)" "$(grep -c 'from-a' "$NEW/$sid.json" || true)" "1"
  fi
  eq "R22 $label: the legacy json was not recreated" "$(test -e "$LEG/$sid.json" || echo absent)" "absent"
}

c_r22_update_top_level() {
  r22_scenario update update '"closes_issues"'
}

c_r22b_other_writers() {
  r22_scenario writestate writestate '"verbose_prompt": *true'
  r22_scenario markstep markstep '"origin": "mark-step"'
  r22_scenario worktree worktree 'r22-wt-path' "$(np "$T/r22-wt-path")"
}

c_r22c_supervisor_lock() {
  local sid o lockd
  new_home r22c
  sid="$(sid_of 2230)"
  o="$T/r22c.out"
  probe_seed "$LEG" "$sid"
  lockd="$LEG/$sid.control/supervisor-state.json.lock"
  mkdir -p "$lockd"
  printf 'held-by-test' >"$lockd/owner"
  bg_probe "$o" finding "$sid" r22c-finding
  sleep 0.6
  mkdir -p "$NEW/$sid.control"
  probe_seed "$NEW" "$sid"
  rm -rf "$lockd"
  wait "$BPID" || true
  eq "R22c appendFinding succeeded" "$(cat "$o")" "true"
  eq "R22c the finding is in the new-root supervisor-state.json" \
    "$(count_in 'r22c-finding' "$NEW/$sid.control/supervisor-state.json")" "1"
  eq "R22c the legacy supervisor-state.json did not receive it" \
    "$(count_in 'r22c-finding' "$LEG/$sid.control/supervisor-state.json")" "0"
}

# R22d: the routing flips on every call (flip-preload.js, loaded through NODE_OPTIONS so
# the production resolver carries no test hook), so only the re-acquire limit ends the loop.
c_r22d_retry_limit() {
  local sid out err before flip
  new_home r22d
  sid="$(sid_of 2240)"
  flip="--require=$A/tests/hooks/feat-2511-state-root-routing/flip-preload.js"
  probe_seed "$LEG" "$sid"
  before="$(cat "$LEG/$sid.json" 2>/dev/null || echo unseeded)"
  out="$(cd "$T/cwd" && run_with_timeout 30 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" NODE_OPTIONS="$flip" \
    HOME="$H" USERPROFILE="$H" node "$PROBE" "$A" update "$sid" 2>/dev/null || true)"
  eq "R22d workflow lock: past 2 retries -> StateLockTimeoutError" "${out%%:*}:$(cut -d: -f2 <<<"$out")" "ERR:StateLockTimeoutError"
  eq "R22d workflow lock: the legacy json is byte-identical" "$(cat "$LEG/$sid.json" 2>/dev/null || echo missing)" "$before"
  eq "R22d workflow lock: no new-root json was written" "$(test -e "$NEW/$sid.json" || echo absent)" "absent"
  err="$T/r22d.err"
  out="$(cd "$T/cwd" && run_with_timeout 30 env -u WORKFLOW_STATE_DIR -u "$OLD_TOKEN" NODE_OPTIONS="$flip" \
    HOME="$H" USERPROFILE="$H" node "$PROBE" "$A" sesslock "$sid" 2>"$err" || true)"
  eq "R22d supervisor lock: undefined and fn never called" "$out" "undefined|called=false"
  eq "R22d supervisor lock: exactly one stderr line" "$(grep -c . "$err" || true)" "1"
}
