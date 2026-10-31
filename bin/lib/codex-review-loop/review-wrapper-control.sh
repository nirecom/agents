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
}

# rwc_check_terminal <label> <current-fingerprint> [<accept-marker-name> <accept-format>]
# — honours a terminal: 8 when the input is unchanged or uncomparable, 9 when a changed
# input follows an unaccepted exit 6 (accept formats only); otherwise clears the guard.
rwc_check_terminal() {
  local label="$1" cur="$2" marker="${3:--}" afmt="${4:-}" prev_rc prev_fp
  [[ -f "$TERMINAL_FILE" ]] || return 0
  prev_rc="$(sed -n '1p' "$TERMINAL_FILE" 2>/dev/null || true)"
  prev_fp="$(sed -n '2p' "$TERMINAL_FILE" 2>/dev/null || true)"
  if [[ -z "$cur" || -z "$prev_fp" ]]; then
    echo "[$label] ERROR: the previous review ended with a terminal exit (code=${prev_rc:-?}) and the reviewed-input fingerprint could not be compared. Keeping the guard armed; change the reviewed input before re-running." >&2
    return 8
  fi
  if [[ "$cur" == "$prev_fp" ]]; then
    echo "[$label] ERROR: the previous review ended with a terminal exit (code=${prev_rc:-?}) and the reviewed input is unchanged. Re-looping now would defeat the 2+1 round cap. Follow 'Escalation by format' in skills/_shared/codex-review-loop/exit-codes.md." >&2
    return 8
  fi
  if [[ "$prev_rc" == "6" && "$marker" != "-" && ! -f "$CONTROL_DIR/$marker" ]]; then
    echo "[$label] The input changed after an exit 6 terminal, but the residual HIGH findings are not accepted. Ask the user via AskUserQuestion; on acceptance run: bin/accept-exit6-residual --session $SESSION_ID --format $afmt --reason <text>, then re-run." >&2
    return 9
  fi
  rm -f "$TERMINAL_FILE"
}

# _rwc_publish <dest> <rc> <fingerprint> — atomic publish of a two-line control marker.
_rwc_publish() {
  local tmp
  tmp="$(mktemp "$CONTROL_DIR/.sg-XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n%s\n' "$2" "$3" > "$tmp"; then
    mv -f "$tmp" "$1" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# rwc_arm_terminal <rc> <fingerprint> — atomic publish of the terminal file.
rwc_arm_terminal() {
  _rwc_publish "$TERMINAL_FILE" "$1" "$2"
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
