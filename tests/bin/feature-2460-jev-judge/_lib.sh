#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, shared-lib, mock-server, scope:issue-specific, pwsh-not-required
# Shared scaffolding for the feature-2460-jev-judge fragments: reuses the jev-shadow fixture
# helpers and mock Jev (echo mode answers whatever keys the request asks), adds the jev-judge
# CLI runner, the in-process probe and two-stage fixture builders. Holds no cases of its own.

if [ -n "${_FEAT2460_JJ_LIB_SOURCED:-}" ]; then
  return 0
fi
_FEAT2460_JJ_LIB_SOURCED=1

__JJ_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$__JJ_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-shadow/_lib.sh"
mock_start

JJ_DIR="$__JJ_CHECKOUT_ROOT/tests/bin/feature-2460-jev-judge"
JJ_PROBE="$(np "$JJ_DIR/judge-probe.js")"
JUDGE="$REPO_N/bin/workflow/jev-judge"
DERIVE="$REPO_N/bin/workflow/derive-complexity-level"
RECORD_CE="$REPO_N/bin/workflow/record-complexity-evaluation"
# A UUID-shaped session id every SID_RE accepts.
SID="11111111-2222-4333-8444-555555555555"

# need_mod <repo-relative path>: one FAIL line naming a not-yet-implemented target, else 0.
# Fragments call `need_mod <p> || return 0` so a missing module costs one clean failure.
need_mod() {
  if [ -e "$__JJ_CHECKOUT_ROOT/$1" ]; then return 0; fi
  fail "MODULE_MISSING: $1" "not implemented yet (expected red until the stage lands)"
  return 1
}

# pb <cmd> [args...]: run the in-process probe; stdout only.
pb() { run_with_timeout 30 node "$JJ_PROBE" "$REPO_N" "$@" 2>/dev/null; }

# jj <subcommand> [args...] [-- VAR=value ...]: run the CLI from the neutral cwd with the
# session and Jev env pinned. Defaults: JEV=on, the sentinel key, JEV_BASE_URL=$MOCK_URL;
# VAR=__unset__ drops a default. Sets JJ_RC, $OUT, $ERR (stderr also appended to $ERR_ALL).
jj() {
  local -a cli=() extra=() sets=()
  local kv name dropped=" " seen_sep=0
  for kv in "$@"; do
    if [ "$kv" = "--" ] && [ "$seen_sep" -eq 0 ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" -eq 1 ]; then extra+=("$kv"); else cli+=("$kv"); fi
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
      "${sets[@]+"${sets[@]}"}" bash "$RWT" 60 node "$JUDGE" "${cli[@]+"${cli[@]}"}" < /dev/null > "$OUT" 2> "$ERR"
  )
  JJ_RC=$?
  cat "$ERR" >> "$ERR_ALL"
}

# live_pid: a pid that is alive for node's process.kill(pid, 0) (the Windows pid under MSYS).
live_pid() { if [ -r "/proc/$$/winpid" ]; then tr -d '\r\n' < "/proc/$$/winpid"; else echo "$$"; fi; }
# kv <KEY>: the value of the first KEY= line of the last jj stdout ("<none>" when absent).
kv() {
  local line
  line="$(grep -m1 "^$1=" "$OUT" 2>/dev/null)" || { echo "<none>"; return 0; }
  printf '%s' "${line#*=}" | tr -d '\r'
}
out_lines() { tr -d '\r' < "$OUT" | wc -l | tr -d ' '; }
out_text() { tr -d '\r' < "$OUT"; }
# fallback_lines: every FALLBACK= line of the last stdout, comma-joined ("" when none), so a
# duplicate line or a second reason shows up instead of hiding behind kv's first match.
fallback_lines() { out_text | grep '^FALLBACK=' | paste -sd, -; }
# keyset <csv>: lowercase, '-' -> '_', sorted, comma-joined (spelling-neutral key comparison).
keyset() { printf '%s' "$1" | tr ',' '\n' | tr 'A-Z-' 'a-z_' | sed '/^$/d' | sort | paste -sd, -; }

# jj_fx <name> [issue-body]: fresh fixture with a full intent and context.md for $SID.
jj_fx() {
  fx_new "$1"
  local body="${2:-Short issue body: add a flag to the report CLI.}"
  printf '# Intent\n\nAdd a --json flag to the report command; no other change.\n' > "$FX/plans/$SID-intent.md"
  printf '# Context\n\n## Issue body\n\n%s\n' "$body" > "$FX/plans/$SID-context.md"
}
# mock_p <defaultP> [<key> <p> ...]: echo mode; each key is set under both spellings.
mock_p() {
  local d="$1" json="" k lk
  shift
  while [ "$#" -ge 2 ]; do
    k="$1"; lk="$(printf '%s' "$k" | tr 'A-Z-' 'a-z_')"
    json="$json\"$k\":$2,\"$lk\":$2,"
    shift 2
  done
  mock_mode "{\"echo\":true,\"defaultP\":$d,\"keyProbs\":{${json%,}}}"
}
# ctl <name>: the session control-dir path of <name> for $SID.
ctl() { pb control-path "$SID" "$1"; }
fixed_csv() {
  local f; f="$(ctl "$1-signals.txt")"
  if [ -f "$f" ]; then tr -d '\r\n' < "$f"; else echo "<absent>"; fi
}
log_count() { if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi; }
# lq <ticket> <expr>: evaluate <expr> over the decision log records of <ticket> (recs, r, all).
lq() { pb log-q "$(np "$LOG")" "$1" "$2"; }
# ticket_file <ticket>: the persisted cli-ticket for <ticket> under the jev state dir.
ticket_file() { find "$JEVDIR" -path '*pending*' -name "*$1*" -type f 2>/dev/null | head -1; }

# jj_query <stage> [point]: query for $SID; sets TICKET from stdout.
jj_query() {
  jj query --session "$SID" --point "${2:-complexity-judge}" --stage "$1" "${@:3}"
  TICKET="$(kv TICKET)"
}
