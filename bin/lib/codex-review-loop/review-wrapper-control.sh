#!/usr/bin/env bash
# bin/lib/codex-review-loop/review-wrapper-control.sh — sourced by the five stage
# wrappers skills/*/scripts/run-codex-review-loop.sh (#2434). Resolves <sid>.control
# once (a legacy PLANS_DIR terminal is migrated first) and owns the terminal guard,
# the review_tests continuing / unreviewed markers and the wsid pointer (#2842).
# Caller globals: SESSION_ID. Sets CONTROL_DIR TERMINAL_FILE.
# Loaded from the wrapper's own tree, so a stub checkout without bin/lib still works.
# Escalation per format and exit code: skills/_shared/codex-review-loop/exit-codes.md.

_RWC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/safe-state-path.sh"
# shellcheck source=bin/lib/safe-state-path.sh
source "$_RWC_LIB" || { echo "review-wrapper-control: cannot load $_RWC_LIB" >&2; exit 4; }

# rwc_resolve <loop-format> <label> — exit 4 (HALT) when the control dir is unusable;
# nothing is ever written to PLANS_DIR instead.
rwc_resolve() {
  local out=""
  out="$(sp_control_dir "$SESSION_ID" "$1-terminal.txt")" || out=""
  if [[ -z "$out" ]]; then
    echo "[$2] ERROR: the control dir of session $SESSION_ID is unusable (HALT, exit 4)." >&2
    exit 4
  fi
  TERMINAL_FILE="$out"
  CONTROL_DIR="${out%/*}"
  RWC_FORMAT="$1"
}

_rwc_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); }

# _rwc_marker_kv <file> <key> — the value of <key>= in an accept marker.
_rwc_marker_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'; }

# _rwc_open_high <loop-format> <ledger> — the open HIGH count of the terminal's ledger.
_rwc_open_high() {
  local root out kv
  root="$(_rwc_root)" || return 1
  # shellcheck source=bin/lib/codex-review-loop/format-params.sh
  source "$root/bin/lib/codex-review-loop/format-params.sh" 2>/dev/null || return 1
  fp_resolve "$1" >/dev/null 2>&1 || return 1
  out="$(bash "$root/bin/concern-ledger" tally --plans-dir "${PLANS_DIR:-}" --session-id "$SESSION_ID" \
    --format "$FP_LEDGER_FORMAT" --ledger "$2" 2>/dev/null)" || return 1
  for kv in $out; do
    [[ "$kv" == open_high=* ]] && { printf '%s' "${kv#open_high=}"; return 0; }
  done
  return 1
}

# _rwc_exit6_cleared <label> <marker> <terminal-fp> — D6: an exit 6 terminal
# releases only when the accept marker equals this terminal's lines 2 and 3 (line 3 empty on
# an old 2-line terminal), or when every HIGH of the ledger line 3 names has since been closed.
_rwc_exit6_cleared() {
  local label="$1" mf="$CONTROL_DIR/$2" tfp="$3" tledger high
  tledger="$(sed -n '3p' "$TERMINAL_FILE" 2>/dev/null | tr -d '\r')"
  if [[ -f "$mf" && "$(_rwc_marker_kv "$mf" terminal_fp)" == "$tfp" \
        && "$(_rwc_marker_kv "$mf" terminal_ledger)" == "$tledger" ]]; then
    return 0
  fi
  [[ -n "$tledger" && -f "$tledger" ]] || return 1
  # A ledger without concern entries reports open_high=0 though the exit 6 HIGHs are lost.
  grep -qE '^C[0-9]+\|' "$tledger" 2>/dev/null || return 1
  high="$(_rwc_open_high "$RWC_FORMAT" "$tledger")" || return 1
  [[ "$high" =~ ^[0-9]+$ ]] && (( high == 0 )) || return 1
  echo "[$label] Every HIGH finding in the exit 6 ledger is now closed; releasing the guard." >&2
}

# rwc_check_terminal <label> <current-fingerprint> [<accept-marker-name> <accept-format>]
# — honours a terminal: 8 when the input is unchanged or uncomparable, 9 when a changed
# input follows an unaccepted exit 6 (accept formats only); otherwise clears the guard.
rwc_check_terminal() {
  local label="$1" cur="$2" marker="${3:--}" afmt="${4:-}" prev_rc prev_fp
  [[ "$marker" != "-" ]] && RWC_MARKER="$marker"
  [[ -f "$TERMINAL_FILE" ]] || return 0
  prev_rc="$(sed -n '1p' "$TERMINAL_FILE" 2>/dev/null | tr -d '\r')"
  prev_fp="$(sed -n '2p' "$TERMINAL_FILE" 2>/dev/null | tr -d '\r')"
  if [[ -z "$cur" || -z "$prev_fp" ]]; then
    echo "[$label] ERROR: the previous review ended with a terminal exit (code=${prev_rc:-?}) and the reviewed-input fingerprint could not be compared. Keeping the guard armed; change the reviewed input before re-running." >&2
    return 8
  fi
  if [[ "$cur" == "$prev_fp" ]]; then
    echo "[$label] ERROR: the previous review ended with a terminal exit (code=${prev_rc:-?}) and the reviewed input is unchanged. Re-looping now would defeat the 2+1 round cap. Follow 'Escalation by format' in skills/_shared/codex-review-loop/exit-codes.md." >&2
    return 8
  fi
  if [[ "$prev_rc" == "6" && "$marker" != "-" ]]; then
    if ! _rwc_exit6_cleared "$label" "$marker" "$prev_fp"; then
      echo "[$label] The input changed after an exit 6 terminal, but the residual HIGH findings are neither closed in the ledger nor accepted. Ask the user via AskUserQuestion; on acceptance run: node \"$(_rwc_root)/bin/accept-exit6-residual\" --session $SESSION_ID --format $afmt --reason \"<text>\", then re-run." >&2
      return 9
    fi
    rm -f "$CONTROL_DIR/$marker"
  fi
  rm -f "$TERMINAL_FILE"
}

# _rwc_publish <dest> <rc> <fingerprint> [<ledger>] — atomic publish of a control marker
# (two lines, or three when a ledger path is given).
_rwc_publish() {
  local tmp lines=("$2" "$3")
  tmp="$(mktemp "$CONTROL_DIR/.sg-XXXXXX" 2>/dev/null)" || return 0
  [[ -n "${4:-}" ]] && lines+=("$4")
  if printf '%s\n' "${lines[@]}" > "$tmp"; then
    mv -f "$tmp" "$1" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# rwc_arm_terminal <rc> <fingerprint> — atomic publish of the terminal file. An exit 6 also
# names the ledger the loop published (line 3); any accept marker of an older terminal goes.
rwc_arm_terminal() {
  local ledger=""
  [[ -n "${RWC_MARKER:-}" ]] && rm -f "$CONTROL_DIR/$RWC_MARKER"
  if [[ "$1" == "6" ]]; then
    ledger="$(sed -n '1p' "$CONTROL_DIR/${RWC_FORMAT:-}-terminal-ledger.txt" 2>/dev/null | tr -d '\r')"
  fi
  _rwc_publish "$TERMINAL_FILE" "$1" "$2" "$ledger"
}

# rwc_input_fp_args <fingerprint> — sets RWC_FP_ARGS, the loop's --input-fingerprint for the
# review record row; empty (with a warning) when the wrapper could not fingerprint its input.
# shellcheck disable=SC2034  # RWC_FP_ARGS is read by the sourcing wrapper
rwc_input_fp_args() {
  RWC_FP_ARGS=()
  if [[ -n "${1:-}" ]]; then
    RWC_FP_ARGS=(--input-fingerprint "$1")
  else
    echo "warning: reviewed-input fingerprint unavailable; the review record row will carry fingerprint=null" >&2
  fi
}

# rwc_arm_continuing <rc> <fingerprint> — #2664: evidence that the review ended on a
# continuing exit (1/5), read by the WARNINGS_ACCEPTED recovery. Never a re-invoke guard.
rwc_arm_continuing() {
  _rwc_publish "$CONTROL_DIR/test-review-continuing.txt" "$1" "$2"
}

# rwc_clear_continuing — drop the previous run's continuing marker so it only ever
# describes the latest review.
rwc_clear_continuing() {
  rm -f "$CONTROL_DIR/test-review-continuing.txt"
}

# rwc_clear_unreviewed [<cc-sid>] — #2842: the review is about to launch, so RT-2's
# "not reviewed yet" marker must go from the wsid and the CC sid dir. rc 1 when one remains.
rwc_clear_unreviewed() {
  local name="test-review-unreviewed.txt" cc_file=""
  rm -f "$CONTROL_DIR/$name" 2>/dev/null || true
  [[ ! -e "$CONTROL_DIR/$name" ]] || return 1
  if [[ -n "${1:-}" && "$1" != "$SESSION_ID" ]]; then
    cc_file="$(sp_control_dir "$1" "$name")" || return 1
    rm -f "$cc_file" 2>/dev/null || true
    [[ ! -e "$cc_file" ]] || return 1
  fi
  return 0
}

# rwc_stage_fallback <loop-format> — #2938 D2: a wrapper-own exit 3 (the review never reached
# the loop) stages the CC-fallback pending first; rc non-zero when it cannot (the caller halts).
rwc_stage_fallback() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || return 1
  node "$root/bin/review-rounds" stage-fallback --session "$SESSION_ID" --format "$1" >/dev/null
}

# rwc_record_wsid_pointer <cc-sid> — #2842: tell the CC-sid handler which wsid holds this
# run's markers. No-op when the ids match; rc 1 (fail-closed) when the write fails.
rwc_record_wsid_pointer() {
  local cc="${1:-}" dest tmp
  [[ -n "$cc" && "$cc" != "$SESSION_ID" ]] || return 0
  dest="$(sp_control_dir "$cc" test-review-wsid.txt)" || return 1
  tmp="$(mktemp "${dest%/*}/.wsid-XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$SESSION_ID" > "$tmp" && mv -f "$tmp" "$dest"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
