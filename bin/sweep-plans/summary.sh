#!/usr/bin/env bash
# bin/sweep-plans/summary.sh — output channel and the run summary of bin/sweep-plans.sh.
# Source-only module. Under --ci-mode stdout carries exactly one JSON line; every
# human-readable line goes through say, which sends it to stderr in that mode.

# Basenames are untrusted: a newline or ESC in one could forge a gate block line or
# garble the terminal. Every control character but tab (a column separator) becomes '?'.
_CTRL_CHARS=$'[\001-\010\012-\037\177]'

# _printable <text> — sets PRINTABLE_OUT; no subshell.
_printable() {
  PRINTABLE_OUT="${1//$_CTRL_CHARS/?}"
}

say() {
  _printable "$*"
  if [[ "${CI_MODE:-0}" == "1" ]]; then printf '%s\n' "$PRINTABLE_OUT" >&2; else printf '%s\n' "$PRINTABLE_OUT"; fi
}

SUMMARY_COUNTERS=(scanned groups_candidates groups_removed groups_skipped_young groups_skipped_revived
  files_removed files_skipped_unrecognized files_non_plan_candidates files_plan_candidates
  files_user_requested_candidates files_unknown_kept groups_approval_candidates
  files_plan_removed files_user_requested_removed classifier_failed)

sweep_plans_counters_init() {
  local c
  for c in "${SUMMARY_COUNTERS[@]}"; do printf -v "$c" '%d' 0; done
  errors=()
}

# The JSON line is encoded by bash builtins alone, so it is emitted even where node is absent.
# _json_str / _json_num write their JSON literal into _json_out (no subshell per value).
_json_str() {
  local LC_ALL=C s="$1" i ch code out=""
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  if [[ "$s" == *[[:cntrl:]]* ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      ch="${s:i:1}"
      printf -v code '%d' "'$ch"
      if ((code >= 0 && code < 32)); then printf -v ch '\\u%04x' "$code"; fi
      out+="$ch"
    done
    s="$out"
  fi
  _json_out="\"$s\""
}

# Mirrors JS Number(): empty -> 0, an integer -> its decimal form, anything else -> null.
_json_num() {
  if [[ -z "$1" ]]; then _json_out=0
  elif [[ "$1" =~ ^(-?)0*([0-9]+)$ ]]; then _json_out="${BASH_REMATCH[1]}$((10#${BASH_REMATCH[2]}))"
  else _json_out=null; fi
}

# _tab_fields <line> — splits on every tab (empty fields kept, unlike IFS read) into _fields.
_tab_fields() {
  local rest="$1"
  _fields=()
  while [[ "$rest" == *$'\t'* ]]; do _fields+=("${rest%%$'\t'*}"); rest="${rest#*$'\t'}"; done
  _fields+=("$rest")
}

_summary_json() {
  local c line json sep f1 f2 f3 f4
  json="{"; sep=""
  for c in "${SUMMARY_COUNTERS[@]}"; do
    _json_num "${!c}"; json+="$sep\"$c\":$_json_out"; sep=","
  done
  json+="$sep\"errors\":["; sep=""
  for line in "${errors[@]}"; do _json_str "$line"; json+="$sep$_json_out"; sep=","; done
  json+="],\"approval_candidates\":["; sep=""
  for line in "${APPROVAL_CANDIDATES[@]}"; do
    _tab_fields "$line"; f1="${_fields[0]}"; f2="${_fields[1]-}"; f3="${_fields[2]-}"; f4="${_fields[3]-}"
    _json_str "$f1"; json+="$sep{\"token\":$_json_out"
    _json_num "$f2"; json+=",\"plan_files\":$_json_out"
    _json_num "$f3"; json+=",\"user_requested_files\":$_json_out"
    _json_num "$f4"; json+=",\"newest\":$_json_out}"; sep=","
  done
  json+="],\"gate_id\":"
  if [[ -n "$gate_id" ]]; then _json_str "$gate_id"; json+="$_json_out"; else json+="null"; fi
  json+=",\"approval_skipped\":["; sep=""
  for line in "${APPROVAL_SKIPPED[@]}"; do
    _tab_fields "$line"; f1="${_fields[0]}"; f2="${_fields[1]-}"
    _json_str "$f1"; json+="$sep{\"token\":$_json_out"
    _json_str "$f2"; json+=",\"reason\":$_json_out}"; sep=","
  done
  printf '%s\n' "$json]}"
}

sweep_plans_summary() {
  local c
  if [[ "$CI_MODE" == "1" ]]; then
    _summary_json
    return 0
  fi
  say "sweep-plans summary:"
  for c in "${SUMMARY_COUNTERS[@]}"; do say "  $c: ${!c}"; done
  say "  errors: ${#errors[@]}"
  if [[ -n "$gate_id" ]]; then say "  gate_id: $gate_id"; fi
  sweep_write_mode_footer
}

# PLANS_DIR does not exist: nothing to scan.
sweep_plans_summary_no_dir() {
  if [[ "$CI_MODE" == "1" ]]; then
    sweep_plans_counters_init
    APPROVAL_CANDIDATES=(); APPROVAL_SKIPPED=(); gate_id=""
    _summary_json
  else
    printf 'plans dir not found: %s\n' "$PLANS_DIR"
  fi
}
