#!/usr/bin/env bash
# bin/lib/codex-review-loop/round-counter.sh — round-counter SSOT for
# bin/run-codex-review-loop (P2-2b/c). Sourced by the loop; caller-scope globals:
# ROUND_FILE LAST_ROUND_FILE ROUND_LOCK ROUND_LOCK_HELD ROUND ROUND_PREV
# ROUND_FILE_EXISTED REDUCE_COMMITTED LEDGER PLANS_DIR PRESTAGED_MODE.
# Depends on die(), sp_publish_stdin, sp_contained_rm (loaded before first call).

acquire_round_lock() {
  local i=0
  until mkdir "$ROUND_LOCK" 2>/dev/null; do
    i=$(( i + 1 ))
    if (( i > 100 )); then
      echo "run-codex-review-loop: another review round is in flight for ${SID}/${FORMAT} (lock: ${ROUND_LOCK}); refusing to allocate a duplicate round number" >&2
      exit 4
    fi
    sleep "${LOCK_SLEEP:-0.1}" 2>/dev/null || sleep 1
  done
  ROUND_LOCK_HELD=1
}
release_round_lock() {
  (( ROUND_LOCK_HELD == 1 )) && rmdir "$ROUND_LOCK" 2>/dev/null || true
  ROUND_LOCK_HELD=0
}
acquire_round_lock_besteffort() {
  mkdir "$ROUND_LOCK" 2>/dev/null && ROUND_LOCK_HELD=1 || true
  return 0
}

# A converged review has no further use for its ledger, but $LEDGER can be
# $LEDGER_OVERRIDE — an arbitrary --ledger path with no containment check of
# its own. Deleting it unconditionally would let an out-of-bounds override
# unlink a file outside $PLANS_DIR, the same destructive-operation class
# cl_finalize already guards with sp_contained_rm (#2025 C6/C8). An override
# that resolves outside $PLANS_DIR is left in place rather than deleted.
cleanup_ledger() {
  sp_contained_rm "$LEDGER" "$PLANS_DIR" 2>/dev/null || true
}

read_round_file() {
  local raw
  raw="$(cat "$ROUND_FILE" 2>/dev/null)" || return 1
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  (( ${#raw} <= 3 )) || return 1
  printf '%s' "$((10#$raw))"
}

write_round_file() {
  # Published through the shared primitive: the old "$ROUND_FILE.tmp.$$" was a
  # predictable name in a shared directory, and mv onto a directory succeeds
  # by moving the temp inside it (#2025 C6).
  local v="$1"
  printf '%s\n' "$v" | sp_publish_stdin "$ROUND_FILE" || die "cannot publish round counter: $ROUND_FILE"
}

_srn_terminate() {
  # Best-effort as before, but published rather than redirected into (C6).
  printf '%s\n' "$ROUND" | sp_publish_stdin "$LAST_ROUND_FILE" || true
  rm -f "$ROUND_FILE"
}
_srn_rollback() {
  if [[ "${REDUCE_COMMITTED:-false}" == "true" ]]; then
    _srn_terminate
    return
  fi
  if [[ -n "${ROUND_PREV:-}" ]]; then
    if (( ROUND_FILE_EXISTED == 1 )); then
      write_round_file "$ROUND_PREV" || true
    else
      rm -f "$ROUND_FILE"
    fi
  fi
}
settle_round_counter() {
  local rc="$1"
  # A prestaged JOIN re-enters a round the reviewer pass already opened and owns
  # the counter for (X1->X2->X3 and the E1 recovery re-run all pass --round):
  # it must not settle a counter it never allocated. A prestaged ADVANCE (the
  # scanner fallback entered with no --round: #2276 S8-d) allocated and wrote the
  # counter itself, so it settles exactly like the reviewer pass below — the
  # fallback round is thereby consumed against the 2+1 cap (S9-c).
  [[ "${PRESTAGED_MODE:-0}" == "1" && "${PRESTAGED_ADVANCED:-0}" != "1" ]] && return 0
  [[ -n "${ROUND_FILE:-}" ]] || return 0
  acquire_round_lock_besteffort
  case "$rc" in
    0|2|6) _srn_terminate ;;
    # exit 1 (NON_APPROVED / CONTINUE) is round-continuing for every format,
    # including the review-only ones (#2276 S9-c): the counter survives so the
    # skill restart that follows is counted as the next round, never a fresh
    # round 1. The 2+1 cap is enforced by review-loop-verdict's CAP argument and
    # the terminal exits above, not by dropping the counter here.
    1)     : ;;
    5)     : ;;
    *)     _srn_rollback ;;
  esac
  release_round_lock
}
