#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, skip-gate, shared-lib, mock-server, scope:issue-specific, pwsh-not-required
# Skip-side scaffolding for the feature-2460-jev-judge fragments (f/g/h/l/m/o skip): sourced
# after _lib.sh. Builds outline/detail fixtures with a legacy workflow state, drives the
# in-process skip probe and the record-skip-judgment CLI. Holds no cases of its own.

if [ -n "${_FEAT2460_JJ_SKIP_LIB_SOURCED:-}" ]; then
  return 0
fi
_FEAT2460_JJ_SKIP_LIB_SOURCED=1

SKIP_PROBE="$(np "$JJ_DIR/skip-probe.js")"
RSJ="$REPO_N/bin/workflow/record-skip-judgment"
# A ticket-shaped id that no query ever issues (record-skip-judgment table rows).
SK_OTHER_TICKET="0123456789abcdef"

# Legacy JSON seeds (the state shape feature-1286 uses): research done, outline or detail pending.
SK_JSON_AT_OUTLINE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}}}'
SK_JSON_AT_DETAIL='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}}}'

# sk_keys <target>: sets K1 K2 to the target's condition keys (CONDITION_SCHEMAS order).
sk_keys() {
  if [ "$1" = "outline" ]; then K1="so_c1"; K2="so_c2"; else K1="sd_single_approach"; K2="sd_no_open_decision"; fi
}

# sk_fx <name> <target> [issue-body] [outline-text|none]: jj_fx plus the workflow state at
# <target> and, for detail, an outline.md (omitted with "none").
sk_fx() {
  local name="$1" target="$2" body="${3:-}" outline="${4:-}"
  if [ -n "$body" ]; then jj_fx "$name" "$body"; else jj_fx "$name"; fi
  sk_keys "$target"
  if [ "$target" = "outline" ]; then
    printf '%s' "$SK_JSON_AT_OUTLINE" > "$FX/wf/$SID.json"
  else
    printf '%s' "$SK_JSON_AT_DETAIL" > "$FX/wf/$SID.json"
    if [ "$outline" != "none" ]; then
      printf '# Outline\n\n%s\n' "${outline:-Single approach: add the flag in report.js; no open decision.}" \
        > "$FX/plans/$SID-outline.md"
    fi
  fi
}

# sp [VAR=value ...] <cmd> [args...]: run the skip probe from the neutral cwd with the Jev env
# pinned like jj (VAR=__unset__ drops a default). Sets SP_RC, $OUT, $ERR (stderr to $ERR_ALL).
sp() {
  local -a extra=() sets=()
  local kv name dropped=" "
  while [ "$#" -gt 0 ]; do
    case "$1" in [A-Z]*=*) extra+=("$1"); shift ;; *) break ;; esac
  done
  for kv in "${extra[@]+"${extra[@]}"}"; do [ "${kv#*=}" = "__unset__" ] && dropped="$dropped${kv%%=*} "; done
  local -a all=("JEV=on" "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=${MOCK_URL:-http://127.0.0.1:1}" "${extra[@]+"${extra[@]}"}")
  for kv in "${all[@]}"; do
    name="${kv%%=*}"
    case "$dropped" in *" $name "*) continue ;; esac
    sets+=("$kv")
  done
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u JEV -u TYPESAFE_API_KEY -u JEV_BASE_URL \
      -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS \
      "${sets[@]+"${sets[@]}"}" bash "$RWT" 60 node "$SKIP_PROBE" "$REPO_N" "$@" < /dev/null > "$OUT" 2> "$ERR"
  )
  SP_RC=$?
  cat "$ERR" >> "$ERR_ALL"
}
# sq <cmd> [args...]: a state read through the probe; stdout only, $OUT untouched.
sq() { run_with_timeout 30 node "$SKIP_PROBE" "$REPO_N" "$@" 2>/dev/null | tr -d '\r'; }
# sk_status <step>: the step status without quotes ("null" when absent).
sk_status() { sq step "$SID" "$1" status | tr -d '"'; }
# sjq <target> <expr>: evaluate <expr> over the recorded skip_judgment (sj).
sjq() { sq sj-q "$SID" "$1" "$2"; }
sk_events() { sq sj-events "$SID" "$1"; }

# rsj [args...]: the record-skip-judgment CLI from the neutral cwd. Sets RSJ_RC, $OUT, $ERR.
rsj() {
  (
    cd "$FX/cwd" || exit 97
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE bash "$RWT" 60 node "$RSJ" "$@" < /dev/null > "$OUT" 2> "$ERR"
  )
  RSJ_RC=$?
  cat "$ERR" >> "$ERR_ALL"
}

# sk_query <target> [entry-extra] [opts-extra] [VAR=value ...]: query <target>-skip at stage
# outline through the module API with the entry forced to mode=production (stage 4 ships the
# skip points as shadow; the gate under test only adopts in production). entry-extra and
# opts-extra are JSON object members without braces. Sets TICKET and SK_AF.
sk_query() {
  local target="$1" ex="${2:-}" ox="${3:-}"
  shift; [ "$#" -gt 0 ] && shift; [ "$#" -gt 0 ] && shift
  local entry="\"mode\":\"production\"${ex:+,$ex}"
  sp "$@" query "{\"sid\":\"$SID\",\"point\":\"$target-skip\",\"stage\":\"outline\",\"entry\":{$entry}${ox:+,$ox}}"
  TICKET="$(kv TICKET)"; SK_AF="$(kv ANSWER_FILE)"
}
# sk_fin [VAR=value ...]: the CLI finalize of $TICKET.
sk_fin() { jj finalize --session "$SID" --ticket "$TICKET" -- "$@"; }
# sk_answer <text>: the subagent's raw answer into the last query's ANSWER_FILE.
sk_answer() {
  if [ "$SK_AF" = "-" ] || [ "$SK_AF" = "<none>" ] || [ -z "$SK_AF" ]; then
    fail "sk_answer: no ANSWER_FILE in query stdout"; return 0
  fi
  printf '%s\n' "$1" > "$SK_AF"
}
# sk_line <K1val> <K2val>: the contract answer line for the current K1/K2.
sk_line() { printf 'SKIP_CONDITIONS: %s=%s, %s=%s' "$K1" "$1" "$K2" "$2"; }
# sk_conds <K1val> <K2val>: the condition object as the fixed-order JSON the checks compare.
sk_conds() { printf '{"%s":%s,"%s":%s}' "$K1" "$1" "$K2" "$2"; }
# sk_sj_conds <target>: the recorded conditions in K1,K2 order as the same JSON shape.
sk_sj_conds() { sjq "$1" "sj && JSON.stringify({\"$K1\": sj.conditions[\"$K1\"], \"$K2\": sj.conditions[\"$K2\"]})"; }
# sk_claims: claim files still on disk (any ticket).
sk_claims() { find "$JEVDIR" -name '*.claimed-*' -type f 2>/dev/null | wc -l | tr -d ' '; }
# sk_sources <ticket>: jev-sources/<ticket> directories still on disk.
sk_sources() { find "$FX" -type d -path "*jev-sources/$1" 2>/dev/null | wc -l | tr -d ' '; }

# sk_crash <crashAt> [entry-json]: finalize $TICKET in-process, stopped at the named boundary.
sk_crash() {
  local entry='{"mode":"production"}'
  [ -n "${2:-}" ] && entry="$2"
  sp finalize "{\"sid\":\"$SID\",\"ticket\":\"$TICKET\",\"crashAt\":\"$1\",\"entry\":$entry}"
}
# sk_sweep: let the pending TTL lapse, then sweep the session (replays claims and orphans).
sk_sweep() { sleep 1.1; sp sweep "$SID" 1; }
# ms_get <target> <field>: a field of the skip owner marker MS as JSON ("absent" when none).
ms_get() { pb json-get "$(np "$(ctl "$1-skip-owner.json")")" "$2"; }
# ms_sha <target>: sha256 of MS ("absent" when none).
ms_sha() { pb sha "$(np "$(ctl "$1-skip-owner.json")")"; }
# sk_done <ticket>: the done marker path ("" when none).
sk_done() { find "$FX" -path '*tickets-done*' -name "$1.json" -type f 2>/dev/null | head -1; }
sk_done_sha() { local f; f="$(sk_done "$1")"; if [ -n "$f" ]; then pb sha "$(np "$f")"; else echo absent; fi; }
# sk_n_rec <ticket> <record_type>: decision-log records of that type for <ticket>.
sk_n_rec() { lq "$1" "recs.filter(x=>x.record_type===\"$2\").length"; }
# sk_settle <ticket>: the settle records of <ticket> as "settle|detail|owner;..." ("" when none).
sk_settle() { lq "$1" 'recs.filter(x=>x.record_type==="settle").map(x=>[x.settle,x.detail,x.owner].join("|")).join(";")'; }
# sk_created <ticket>: created_ms of a still-pending ticket ("absent" when the file is gone).
sk_created() {
  local f; f="$(ticket_file "$1")"
  if [ -n "$f" ]; then pb json-get "$(np "$f")" created_ms; else echo absent; fi
}
