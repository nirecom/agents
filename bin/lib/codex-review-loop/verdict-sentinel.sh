#!/usr/bin/env bash
# bin/lib/codex-review-loop/verdict-sentinel.sh — the one exit -> verdict-name table of
# bin/run-codex-review-loop and the single place that ends a run with a verdict (#2937 D7).
# Sourced by the loop. Caller-scope globals: TMP_OUT FINAL_RC VS_DIAG DOWNGRADED_MEDIUM
# CONTROL_DIR FORMAT LEDGER. Depends on rr_record_round / rr_older_input (review-record.sh).

VS_DIAG="${VS_DIAG:-}"
DOWNGRADED_MEDIUM="${DOWNGRADED_MEDIUM:-0}"

# vs_name <rc> — the sentinel name of a verdict exit; non-zero for an exit without a verdict (3/4).
vs_name() {
  case "$1" in
    0) printf 'APPROVED' ;;
    1) printf 'NEEDS_REVISION' ;;
    2) printf 'ESCALATE' ;;
    5) printf 'AUTO_EXTEND' ;;
    6) printf 'HIGH_UNRESOLVED' ;;
    7) printf 'FINALIZE_FAILED' ;;
    *) return 1 ;;
  esac
}

# vs_publish_terminal_ledger — on exit 6, name the ledger the stage wrapper's exit-9 guard judges
# (<fmt>-terminal-ledger.txt). The old file goes first so a failed write never names a stale ledger.
vs_publish_terminal_ledger() {
  local dest="$CONTROL_DIR/$FORMAT-terminal-ledger.txt" tmp
  rm -f "$dest"
  tmp="$(mktemp "$CONTROL_DIR/.tl-XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "$LEDGER" > "$tmp"; then
    mv -f "$tmp" "$dest" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# vs_older_input_block — D8: display-only list of open concerns raised against an earlier input.
vs_older_input_block() {
  local out id r
  out="$(rr_older_input)"
  [[ -n "$out" ]] || return 0
  printf '\n### Older-input concerns (raised against an earlier input)\n'
  while read -r id r; do
    [[ -n "$id" ]] && printf -- '- %s (round %s)\n' "$id" "$r"
  done <<< "$out"
  return 0
}

# vs_emit <rc> — record the round, then body, diagnostic, older-input block, downgrade note
# and the sentinel as the last stdout line; exits the process with <rc>.
vs_emit() {
  local rc="$1" name
  if ! name="$(vs_name "$rc")"; then
    echo "run-codex-review-loop: internal error: exit $rc has no verdict sentinel" >&2
    exit 4
  fi
  # shellcheck disable=SC2034  # read by the loop's EXIT trap (settle_round_counter)
  FINAL_RC="$rc"
  if ! rr_record_round "$rc"; then
    [[ -n "${TMP_OUT:-}" && -f "$TMP_OUT" ]] && cat "$TMP_OUT"
    [[ -n "$VS_DIAG" ]] && printf '%s\n' "$VS_DIAG"
    exit 4
  fi
  (( rc == 6 )) && vs_publish_terminal_ledger
  [[ -n "${TMP_OUT:-}" && -f "$TMP_OUT" ]] && cat "$TMP_OUT"
  [[ -n "$VS_DIAG" ]] && printf '%s\n' "$VS_DIAG"
  vs_older_input_block
  if [[ "$DOWNGRADED_MEDIUM" =~ ^[0-9]+$ ]] && (( DOWNGRADED_MEDIUM > 0 )); then
    printf 'REVIEW_LOOP_NOTE: downgraded-medium=%s (open MEDIUM at the round cap; information only, not a WARNINGS gap)\n' "$DOWNGRADED_MEDIUM"
  fi
  printf 'REVIEW_LOOP_VERDICT: %s (exit %s)\n' "$name" "$rc"
  exit "$rc"
}
