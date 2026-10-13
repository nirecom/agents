#!/usr/bin/env bash
# web-merge-poller.sh — #2527 4-5: the background web-merge poller and the resume-time PR check.
# Tests: skills/get-release-approval/scripts/wait-web-merge.sh, skills/get-release-approval/scripts/preflight.sh
# Tags: scope:issue-specific, workflow, release-phase, web-merge, poller, gh-stub, glab-stub
# TL2: spawns wait-web-merge.sh with --interval 0/1 against node-copy gh / glab stubs; each
# pr-state run pops the next answer from FAKE_PRSTATE_SEQ and logs "<ms>|<cwd>" (fake-forge.js).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): the harness relaunching Claude when the run_in_background poller
# exits, and a live forge's rate-limit headers. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup
rp_fake_forge "$RP_TMP/forgebin" gh glab
POLLER="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/scripts/wait-web-merge.sh"
PREFLIGHT_SH="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/scripts/preflight.sh"
SEQ="$(np "$RP_TMP/seq")"
PSLOG="$(np "$RP_TMP/prstate.log")"
GH_URL="https://github.com/example/repo.git"
GL_URL="https://gitlab.com/example/repo.git"

# seq_set <state>... — the pr-state answers in order (the last one sticks); clears the call log.
seq_set() { printf '%s\n' "$@" > "$RP_TMP/seq"; rm -f "$RP_TMP/seq.cur"; : > "$RP_TMP/prstate.log"; }
# poll <args...> — the poller's stdout, run from inside the worktree; stderr to poll.err and the
# exit code to poll.rc (poll runs inside $(...), so the code is handed back through a file).
poll() {
  local rc
  FAKE_PRSTATE_SEQ="$SEQ" FAKE_PRSTATE_LOG="$PSLOG" run_with_timeout 120 bash "$POLLER" "$@" 2>"$RP_TMP/poll.err"
  rc=$?
  printf '%s' "$rc" > "$RP_TMP/poll.rc"
  return "$rc"
}
# prc — the exit code of the last poll; every terminal WEB_MERGE value exits 0 (plan 4-5).
prc() { cat "$RP_TMP/poll.rc" 2>/dev/null || echo "<none>"; }
calls() { if [ -s "$RP_TMP/prstate.log" ]; then grep -c . "$RP_TMP/prstate.log"; else echo 0; fi; }
pidfile() { printf '%s/web-merge-poller-%s.pid' "$WORKFLOW_STATE_DIR" "$1"; }
use_origin() { git -C "$RP_REPO" remote set-url origin "$1"; }

case_begin "poller: OPEN -> OPEN -> MERGED ends merged" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set OPEN OPEN MERGED
out="$(poll --session wp-merged --repo "$RP_REPO_M" --interval 0)"
check "WEB_MERGE merged" "$(field "$out" WEB_MERGE)" "merged"
check "merged: exit 0" "$(prc)" "0"
check "three pr-state calls" "$(calls)" "3"
check "pid file removed on exit" "$([ -e "$(pidfile wp-merged)" ] && echo present || echo absent)" "absent"
case_end

case_begin "poller: cwd is outside the worktree" "skills/get-release-approval/scripts/wait-web-merge.sh"
check "sanity: the log is non-empty" "$([ "$(calls)" -gt 0 ] && echo yes || echo no)" "yes"
inside=0
repo_lc="${RP_REPO_M,,}"
while IFS='|' read -r _ts cwd; do
  [ -z "$cwd" ] && continue
  case "${cwd,,}" in "$repo_lc"|"$repo_lc"/*) inside=$((inside + 1)) ;; esac
done < "$RP_TMP/prstate.log"
check "no pr-state run had its cwd inside the worktree" "$inside" "0"
case_end

case_begin "poller: CLOSED ends closed" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set CLOSED
out="$(poll --session wp-closed --repo "$RP_REPO_M" --interval 0)"
check "WEB_MERGE closed" "$(field "$out" WEB_MERGE)" "closed"
check "closed: exit 0" "$(prc)" "0"
case_end

case_begin "poller: transient failures between OPEN answers are tolerated" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set OPEN FAIL OPEN FAIL MERGED
out="$(poll --session wp-flaky --repo "$RP_REPO_M" --interval 0 --max-failures 3)"
check "WEB_MERGE merged" "$(field "$out" WEB_MERGE)" "merged"
check "five pr-state calls" "$(calls)" "5"
case_end

case_begin "poller: consecutive failures hit --max-failures and end error with the reason" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set AUTH
out="$(poll --session wp-auth --repo "$RP_REPO_M" --interval 0 --max-failures 3)"
check "WEB_MERGE error" "$(field "$out" WEB_MERGE)" "error"
check "error (max-failures): exit 0" "$(prc)" "0"
check "exactly three pr-state calls" "$(calls)" "3"
check "stderr names the reason (auth|401|credential) auth|401|credential" "$(grep -Eiq 'auth|401|credential' "$RP_TMP/poll.err" && echo yes || echo no)" "yes"
case_end

case_begin "poller: --deadline 0 ends timeout; the defaults are 3600 / 30 / 10" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set OPEN
out="$(poll --session wp-deadline --repo "$RP_REPO_M" --interval 0 --deadline 0)"
check "WEB_MERGE timeout" "$(field "$out" WEB_MERGE)" "timeout"
check "timeout: exit 0" "$(prc)" "0"
for n in 3600 30 10; do
  check "default $n appears in the poller" "$(grep -Eq "(^|[^0-9])$n([^0-9]|\$)" "$POLLER" 2>/dev/null && echo yes || echo no)" "yes"
done
case_end

case_begin "poller: a rate limit doubles the interval; a success resets it" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set RATELIMIT RATELIMIT OPEN OPEN MERGED
out="$(poll --session wp-rate --repo "$RP_REPO_M" --interval 1)"
check "WEB_MERGE merged" "$(field "$out" WEB_MERGE)" "merged"
mapfile -t ts < <(cut -d'|' -f1 "$RP_TMP/prstate.log")
if [ "${#ts[@]}" -ge 4 ]; then
  g1=$((ts[1] - ts[0])); g2=$((ts[2] - ts[1])); g3=$((ts[3] - ts[2]))
  check "gap after 1st rate limit >= 1900ms (got $g1)" "$([ "$g1" -ge 1900 ] && echo yes || echo no)" "yes"
  check "gap after 2nd rate limit >= 3900ms (got $g2)" "$([ "$g2" -ge 3900 ] && echo yes || echo no)" "yes"
  check "gap after a success < 3000ms (got $g3)" "$([ "$g3" -lt 3000 ] && echo yes || echo no)" "yes"
else
  fail "rate-limit gaps" "expected >= 4 pr-state calls, got ${#ts[@]}"
fi
# The doubled interval is capped at 300s (plan 4-5); waiting that long is out of TL2 budget,
# so the cap is pinned as a literal in the poller like the defaults above.
check "rate-limit backoff cap 300 appears in the poller" "$(grep -Eq '(^|[^0-9])300([^0-9]|$)' "$POLLER" 2>/dev/null && echo yes || echo no)" "yes"
case_end

case_begin "poller: a missing --repo ends error at once with no pr-state call" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set OPEN
out="$(poll --session wp-norepo --repo "$(np "$RP_TMP/no-such-wt")" --interval 0)"
check "WEB_MERGE error" "$(field "$out" WEB_MERGE)" "error"
check "missing --repo: exit 0" "$(prc)" "0"
check "no pr-state call" "$(calls)" "0"
check "missing --repo: no pid file left" "$([ -e "$(pidfile wp-norepo)" ] && echo present || echo absent)" "absent"
case_end

case_begin "poller: single launch per session (live pid -> already-running, first keeps going)" "skills/get-release-approval/scripts/wait-web-merge.sh"
seq_set OPEN
FAKE_PRSTATE_SEQ="$SEQ" FAKE_PRSTATE_LOG="$PSLOG" bash "$POLLER" --session wp-single --repo "$RP_REPO_M" --interval 1 >"$RP_TMP/first.out" 2>"$RP_TMP/first.err" &
first=$!
for _ in $(seq 1 100); do [ -s "$(pidfile wp-single)" ] && break; sleep 0.2; done
check "pid file written by the first poller" "$([ -s "$(pidfile wp-single)" ] && echo yes || echo no)" "yes"
out="$(poll --session wp-single --repo "$RP_REPO_M" --interval 0)"
check "second launch: WEB_MERGE already-running" "$(field "$out" WEB_MERGE)" "already-running"
check "already-running: exit 0" "$(prc)" "0"
check "first poller still alive" "$(kill -0 "$first" 2>/dev/null && echo alive || echo dead)" "alive"
# Heartbeat: every poll touches the pid file, so it is fresh while the poller polls.
check "pid file is fresh while polling (mtime within the last minute)" "$([ -n "$(find "$(pidfile wp-single)" -mmin -1 2>/dev/null)" ] && echo fresh || echo stale)" "fresh"
printf 'MERGED\n' > "$RP_TMP/seq"
for _ in $(seq 1 150); do kill -0 "$first" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$first" 2>/dev/null; then kill "$first" 2>/dev/null; fi
wait "$first" 2>/dev/null
check "first poller: WEB_MERGE merged" "$(field "$(cat "$RP_TMP/first.out")" WEB_MERGE)" "merged"
check "pid file removed after the first exits" "$([ -e "$(pidfile wp-single)" ] && echo present || echo absent)" "absent"
case_end

case_begin "poller: a dead pid in the pid file is taken over" "skills/get-release-approval/scripts/wait-web-merge.sh"
mkdir -p "$WORKFLOW_STATE_DIR"
printf '999999\n' > "$(pidfile wp-stale)"
seq_set MERGED
out="$(poll --session wp-stale --repo "$RP_REPO_M" --interval 0)"
check "WEB_MERGE merged (not already-running)" "$(field "$out" WEB_MERGE)" "merged"
check "pid file removed on exit" "$([ -e "$(pidfile wp-stale)" ] && echo present || echo absent)" "absent"
case_end

case_begin "poller: GitLab stub gives the same results" "skills/get-release-approval/scripts/wait-web-merge.sh"
use_origin "$GL_URL"
: > "$RP_TMP/forge.log"
seq_set MERGED
out="$(poll --session wp-gl-m --repo "$RP_REPO_M" --interval 0)"
check "gitlab MERGED -> merged" "$(field "$out" WEB_MERGE)" "merged"
seq_set CLOSED
out="$(poll --session wp-gl-c --repo "$RP_REPO_M" --interval 0)"
check "gitlab CLOSED -> closed" "$(field "$out" WEB_MERGE)" "closed"
check_contains "glab was the forge queried" "$(cat "$RP_TMP/forge.log")" "|glab mr view"
check_not_contains "gh never called on gitlab" "$(cat "$RP_TMP/forge.log")" "|gh "
use_origin "$GH_URL"
case_end

# Resume: a session waiting on the web merge (pull_request, AUTO_MERGE_PR=off fixed, push_branch
# complete, user_verification pending) re-enters through the preflight's PR check.
RESUME_SPEC='"path":"pull_request","autoMerge":"off","entered":true,"upto":"user_verification","steps":"user_verification=pending"'
pf() { (cd "$RP_TMP" && RUN_TL4=off run_with_timeout 120 bash "$PREFLIGHT_SH" "$@" 2>"$RP_TMP/pf.err"); }
uv_complete_n() { ev_query "$1" 'e.filter((x) => x.kind === "step_status" && x.step === "user_verification" && x.status === "complete").length'; }

case_begin "resume: MERGED -> web_merge_done, then next-step settles merge_to_main" "skills/get-release-approval/scripts/preflight.sh"
mk_state "{\"sid\":\"wp-res-m\",$RESUME_SPEC}"
out="$(FAKE_FORGE_STATE=MERGED pf --session wp-res-m --repo "$RP_REPO")"
check "PREFLIGHT web_merge_done" "$(field "$out" PREFLIGHT)" "web_merge_done"
out="$(FAKE_FORGE_STATE=MERGED run_next_step wp-res-m)"
check "merge_to_main complete" "$(last_status wp-res-m merge_to_main)" "complete"
check "NEXT_SKILL worktree-end" "$(field "$out" NEXT_SKILL)" "worktree-end"
check "no user_verification complete event" "$(uv_complete_n wp-res-m)" "0"
case_end

case_begin "resume: OPEN + CLEAN -> web_merge_pending; CLOSED -> web_merge_closed" "skills/get-release-approval/scripts/preflight.sh"
mk_state "{\"sid\":\"wp-res-o\",$RESUME_SPEC}"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf --session wp-res-o --repo "$RP_REPO")"
check "OPEN+CLEAN: PREFLIGHT web_merge_pending" "$(field "$out" PREFLIGHT)" "web_merge_pending"
mk_state "{\"sid\":\"wp-res-c\",$RESUME_SPEC}"
out="$(FAKE_FORGE_STATE=CLOSED pf --session wp-res-c --repo "$RP_REPO")"
check "CLOSED: PREFLIGHT web_merge_closed" "$(field "$out" PREFLIGHT)" "web_merge_closed"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
