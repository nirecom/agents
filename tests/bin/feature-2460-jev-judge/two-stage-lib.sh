#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, shared-lib, module-api, scope:issue-specific, pwsh-not-required
# Shared helpers for the complexity-side two-stage fragments (d, e, k, l, o, p, r), sourced
# after _lib.sh: the module-API probe runner, Jev input header readers and fixture builders.
# Holds no cases of its own.

if [ -n "${_FEAT2460_TS_LIB_SOURCED:-}" ]; then
  return 0
fi
_FEAT2460_TS_LIB_SOURCED=1

TS_PROBE="$(np "$JJ_DIR/two-stage-probe.js")"

# tsp <cmd> [args...] [-- VAR=value ...]: run two-stage-probe.js with the same env pinning
# as jj (JEV=on, the sentinel key, JEV_BASE_URL=$MOCK_URL; VAR=__unset__ drops one).
# Sets TS_RC, $OUT, $ERR (stderr also appended to $ERR_ALL).
tsp() {
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
      "${sets[@]+"${sets[@]}"}" bash "$RWT" 60 node "$TS_PROBE" "$REPO_N" "${cli[@]+"${cli[@]}"}" < /dev/null > "$OUT" 2> "$ERR"
  )
  TS_RC=$?
  cat "$ERR" >> "$ERR_ALL"
}
# tpb <cmd> [args...]: the probe's stdout only (fixture seeding, constants).
tpb() { run_with_timeout 30 node "$TS_PROBE" "$REPO_N" "$@" 2>/dev/null; }
# jev_budget: MAX_JEV_INPUT_CHARS as the module exports it (MODULE_MISSING:... before it exists).
# Over-budget fixtures are sized from it so a budget change cannot turn them into in-budget ones.
jev_budget() { tpb jev-input-budget; }

# F_PRODUCTION: the fixture override that runs complexity-judge in mode=production (the CLI
# owns the record and the gate applies). The shipped registry mode changes per stage, so a
# case that needs production passes this, or f_production_with, at the call site.
F_PRODUCTION='{"entryPatch":{"complexity-judge":{"mode":"production"}}}'
# f_production_with <json-fields>: F_PRODUCTION plus extra top-level option fields.
f_production_with() { printf '{"entryPatch":{"complexity-judge":{"mode":"production"}},%s}' "$1"; }
# F_SHADOW_CLI: mode=shadow with subagent_type removed, so the recording owner stays the CLI.
F_SHADOW_CLI='{"entryPatch":{"complexity-judge":{"mode":"shadow","subagent_type":"__unset__"}}}'
# F_SHADOW_HOOK: mode=shadow with a subagent_type, so the recording owner is the hook.
F_SHADOW_HOOK='{"entryPatch":{"complexity-judge":{"mode":"shadow","subagent_type":"complexity-judge"}}}'

# ts_query <stage> [point] [opts-json] [-- VAR=value ...]: module-API query; sets TICKET, JEV_INPUT.
# With no opts the shipped registry entry is used as-is.
ts_query() {
  local stage="$1" point="${2:-complexity-judge}" opts="${3:-}"
  [ -n "$opts" ] || opts='{}'
  shift; [ "$#" -gt 0 ] && shift; [ "$#" -gt 0 ] && shift
  tsp query "$SID" "$point" "$stage" "$opts" "$@"
  TICKET="$(kv TICKET)"; JEV_INPUT="$(kv JEV_INPUT_FILE)"
}
# ts_fin <opts-json> [-- VAR=value ...]: module-API finalize of $TICKET.
ts_fin() { local o="$1"; shift; tsp finalize "$SID" "$TICKET" "$o" "$@"; }

# answer_with <text>: write the subagent answer to the last query's ANSWER_FILE (if any).
answer_with() {
  local f; f="$(kv ANSWER_FILE)"
  if [ "$f" = "-" ] || [ "$f" = "<none>" ]; then return 0; fi
  printf '%s\n' "$1" > "$f"
}
# tk <dotted-key>: a field of the persisted ticket for $TICKET (before finalize), or "absent".
tk() {
  local f; f="$(ticket_file "$TICKET")"
  if [ -z "$f" ]; then echo absent; return 0; fi
  pb json-get "$(np "$f")" "$1"
}

# jev_input_header: the Jev input lines before the first "## " section (the state header).
jev_input_header() { [ -f "$JEV_INPUT" ] && tr -d '\r' < "$JEV_INPUT" | sed '/^## /,$d'; }
# jev_input_state <section>: full|truncated|absent as the header reports it ("<none>" if unreported).
jev_input_state() {
  local v
  v="$(jev_input_header | grep -oE "(^|[^a-z])$1[\"']? *[:=] *(full|truncated|absent)" | head -1 | grep -oE '(full|truncated|absent)$')"
  printf '%s' "${v:-<none>}"
}
# jev_input_source_names: the entries listed under the header's "sources:" line, as written, sorted.
jev_input_source_names() {
  jev_input_header | tr '\\' '/' | sed -n '/^sources:[[:space:]]*$/,/^sources_unavailable/p' | sed '1d;$d' | sed '/^[[:space:]]*$/d' | sort
}
# jev_input_sources: those entries as paths, '/'-separated, sorted. The header names a copy by
# its file name only, so a bare name is resolved against jev-sources/<ticket>; an entry that
# already carries a directory is printed as written.
jev_input_sources() {
  local d n; d="$(copies_dir)"
  [ -n "$d" ] && d="$(np "$d")"
  jev_input_source_names | while IFS= read -r n; do
    case "$n" in
      */*) printf '%s\n' "$n" ;;
      *) if [ -n "$d" ]; then printf '%s/%s\n' "$d" "$n"; else printf '%s\n' "$n"; fi ;;
    esac
  done | sort
}
# jev_input_any_path_to <dir>: count of header lines naming a path inside <dir>.
jev_input_any_path_to() { jev_input_header | tr '\\' '/' | grep -cF "$1"; }
# jev_input_unavail: the header's sources_unavailable value ("<none>" if the field is missing).
jev_input_unavail() {
  local v
  v="$(jev_input_header | grep -m1 -E "^[-* ]*sources_unavailable[\"']? *[:=]" | sed -E 's/^[^:=]*[:=] *//')"
  printf '%s' "${v:-<none>}"
}
# copies_dir: the jev-sources/<ticket> directory of $TICKET ("" when absent).
copies_dir() { find "$FX" -type d -path "*jev-sources/$TICKET" 2>/dev/null | head -1; }
copy_count() { local d; d="$(copies_dir)"; if [ -n "$d" ]; then find "$d" -type f | wc -l | tr -d ' '; else echo 0; fi; }

# mk_bytes <file> <n>: a file of exactly n bytes ('x' filler, no newline).
mk_bytes() { head -c "$2" /dev/zero | tr '\0' 'x' > "$1"; }
# seed_steps <json>: fresh workflow state for $SID with the given {step: status} map.
seed_steps() { check "fixture: workflow state seeded" "ok" "$(tpb state-steps "$SID" "$1")"; }
# csv_allowlisted: "ok" when SIGNALS_CSV is empty or allowlisted ids / S0 only.
csv_allowlisted() {
  local v id='(S1b-wide-change|S2-architecture|S3-security|S4-installer|S5-breaking|S0-undecidable)'
  v="$(kv SIGNALS_CSV)"
  if [[ -z "$v" || "$v" =~ ^$id(,$id)*$ ]]; then
    echo ok
  else
    echo "bad:$v"
  fi
}
no_secret_leak() {
  check "$1: the sentinel API key appears in no fixture file" "absent" "$(grep_absent "$SENTINEL_KEY" "$FX/state" "$FX/wf" "$FX/plans")"
  check "$1: the sentinel API key appears in no stderr" "absent" "$(grep_absent "$SENTINEL_KEY" "$ERR_ALL")"
}
