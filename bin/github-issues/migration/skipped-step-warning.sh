# skipped-step-warning.sh — sourced by orchestrate.sh (#1693).
#
# `--from-step N` jumps straight to N. Steps strictly between the recorded
# current_step and N are then never run, and nothing later fails loudly about
# it. The skipped set is (current_step, FROM_STEP) exclusive — empty exactly
# when FROM_STEP <= current_step + 1, which covers resume, re-run and backwards
# jumps alike.
#
# Read the state file directly: state_load runs only in live mode, so a dry-run
# would otherwise have no current_step to compare against.
#
# Expects REPO_DIR, FROM_STEP, ACK_SKIPPED to be set by the sourcing script.

_recorded_current_step() {
  local sf="$REPO_DIR/.migration-state.json" n
  [ -f "$sf" ] || { echo 0; return 0; }
  n="$(tr -d ' \n' < "$sf" | sed -n 's/.*"current_step":\([0-9][0-9]*\).*/\1/p')"
  [ -n "$n" ] || n=0
  echo "$n"
}

_describe_step() {
  case "$1" in
    2) echo "History migration (canary-gated)" ;;
    3) echo "Ordering gate + todo migration (canary-gated)" ;;
    4) echo "Projects v2 board creation + Content Date backfill" ;;
    5) echo "Commit-comment backfill + state cleanup" ;;
    *) echo "(no description)" ;;
  esac
}

_warn_skipped_steps() {
  local cur first last n
  cur="$(_recorded_current_step)"
  first=$((cur + 1))
  last=$((FROM_STEP - 1))
  [ "$last" -ge "$first" ] || return 0

  if [ "$ACK_SKIPPED" -eq 1 ]; then
    echo "NOTE: skipped steps acknowledged via --ack-skipped-steps (range ${first}-${last} was never run)." >&2
    return 0
  fi

  echo "WARNING: this invocation skips work that was never run." >&2
  echo "         Never run, and not part of this invocation:" >&2
  n="$first"
  while [ "$n" -le "$last" ]; do
    echo "           - Step $n: $(_describe_step "$n")" >&2
    if [ "$n" -eq 4 ]; then
      echo "             Consequence: migrated issues stay off the Projects v2 board and" >&2
      echo "             carry no Content Date; no later step reports this as a failure." >&2
    fi
    n=$((n + 1))
  done
  echo "         Re-run from the earliest of those, or pass --ack-skipped-steps to proceed knowingly." >&2
}
