#!/usr/bin/env bash
# bin/lib/codex-review-loop/control-paths.sh — the control-file paths of
# bin/run-codex-review-loop (#2434). Every one lives in <WORKFLOW_STATE_DIR>/<sid>.control/;
# PLANS_DIR keeps only artifacts. An unusable control dir halts the loop (exit 4).
# Caller globals: SID FORMAT LEDGER_FORMAT LEDGER_OVERRIDE. Needs sp_control_dir.
# Sets: CONTROL_DIR CONTEXT_OUT MARKER LEDGER ROUND_FILE LAST_ROUND_FILE ROUND_LOCK ROUND_LOCK_HELD.

# cp_resolve <name> — the control path of <name>; resolving it by name migrates the
# session's legacy PLANS_DIR control files first (control-dir.js controlPath).
cp_resolve() {
  local out=""
  out="$(sp_control_dir "$SID" "$1")" || out=""
  if [[ -z "$out" ]]; then
    echo "run-codex-review-loop: the control dir of session $SID is unusable (resolving $1); HALT" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# The round counter is addressed by the loop format, the ledger by the shared ledger
# token: security-code and the security-plan review share one ledger while keeping
# separate round counters (#2276 S8-a).
ROUND_FILE="$(cp_resolve "$FORMAT-round-number.txt")" || exit 4
CONTROL_DIR="${ROUND_FILE%/*}"
LAST_ROUND_FILE="$(cp_resolve "$FORMAT-last-round.txt")" || exit 4
if [[ -n "$LEDGER_OVERRIDE" ]]; then
  LEDGER="$LEDGER_OVERRIDE"
else
  LEDGER="$(cp_resolve "$LEDGER_FORMAT-concern-ledger.txt")" || exit 4
fi
CONTEXT_OUT="$CONTROL_DIR/codex-context.md"
MARKER="$CONTROL_DIR/codex-context.$FORMAT.built"
ROUND_LOCK="$ROUND_FILE.lock"
ROUND_LOCK_HELD=0
export CL_CONTROL_DIR="$CONTROL_DIR"
