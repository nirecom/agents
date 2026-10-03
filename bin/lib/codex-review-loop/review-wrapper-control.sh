#!/usr/bin/env bash
# bin/lib/codex-review-loop/review-wrapper-control.sh — sourced by the five stage
# wrappers skills/*/scripts/run-codex-review-loop.sh (#2434). Resolves <sid>.control
# once (a legacy PLANS_DIR terminal is migrated first) and owns the terminal guard.
# Caller globals: AGENTS_CONFIG_DIR SESSION_ID. Sets CONTROL_DIR TERMINAL_FILE.
# Loaded from the wrapper's own tree, so a stub AGENTS_CONFIG_DIR without bin/lib still works.
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

# rwc_arm_terminal <rc> <fingerprint> — atomic publish of the terminal file.
rwc_arm_terminal() {
  local tmp
  tmp="$(mktemp "$CONTROL_DIR/.sg-XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n%s\n' "$1" "$2" > "$tmp"; then
    mv -f "$tmp" "$TERMINAL_FILE" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}
