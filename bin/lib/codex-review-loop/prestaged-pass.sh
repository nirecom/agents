#!/usr/bin/env bash
# bin/lib/codex-review-loop/prestaged-pass.sh — PRESTAGED (scanner fallback) pass
# for bin/run-codex-review-loop (#2276 S8-d), extracted verbatim under
# rules/coding/file-split.md Pattern A to keep the entrypoint under the 500-line
# HARD limit. Sourced by the loop: reads/writes its caller-scope round & ledger
# globals and calls die(), the round-counter/ledger helpers and
# dispatch_prestaged_verdict (all loaded before the first call). `exit` here ends
# the process, as at the original call site.

# prestaged_next_round — the round an ADVANCE would allocate (ROUND_PREV + 1), read only.
# Sets ROUND_PREV / ROUND_FILE_EXISTED and prints the round; non-zero on a corrupt counter.
prestaged_next_round() {
  ROUND_FILE_EXISTED=0
  ROUND_PREV=0
  if [[ -f "$ROUND_FILE" ]]; then
    ROUND_FILE_EXISTED=1
    if ! ROUND_PREV="$(read_round_file)"; then
      echo "run-codex-review-loop: round counter is corrupt: ${ROUND_FILE} (content is not a bare integer 1-999); inspect it and re-run with --force-round <N> once the correct round is known" >&2
      return 1
    fi
  fi
  printf '%s\n' "$(( ROUND_PREV + 1 ))"
}

# prestaged_advance_round — allocate and PERSIST the next round under the round lock
# (PRESTAGED_ADVANCED=1). A fresh cycle archives the prior cycle's ledger first;
# PP_ARCHIVE_PATH names where it went. Any failure exits 4 (#2256 C16 archive-or-halt).
prestaged_advance_round() {
  local own_lock=0
  # The path-kind round already holds the lock until its EXIT trap (#2478 C2).
  if (( ${ROUND_LOCK_HELD:-0} != 1 )); then
    acquire_round_lock
    own_lock=1
  fi
  # Called in this shell (not $(...)) so ROUND_PREV / ROUND_FILE_EXISTED survive.
  prestaged_next_round > /dev/null || exit 4
  ROUND=$(( ROUND_PREV + 1 ))
  write_round_file "$ROUND"
  PRESTAGED_ADVANCED=1
  if (( ROUND == 1 && ROUND_FILE_EXISTED == 0 )) && [[ -f "${LEDGER:-}" ]]; then
    local _arch
    if ! _arch="$(mktemp "${CONTROL_DIR}/.prev-XXXXXX" 2>/dev/null)"; then
      echo "run-codex-review-loop: cannot create archive temp; halting to avoid reducing into stale terminal ledger" >&2
      exit 4
    fi
    if ! mv -f "${LEDGER}" "$_arch"; then
      rm -f "$_arch"
      echo "run-codex-review-loop: cannot archive prior cycle ledger; halting to avoid reducing into stale terminal ledger" >&2
      exit 4
    fi
    # shellcheck disable=SC2034  # read by prestaged-path-pass.sh (pp_round_restore)
    PP_ARCHIVE_PATH="$_arch"
  fi
  (( own_lock == 1 )) && release_round_lock
  return 0
}

# Joins the current round, no reviewer run, no counter advance. stage ->
# per-round completeness -> reduce -> verdict -> per-round terminal artifact
# when unconverged (#2276 S8-d).
run_prestaged_pass() {
  # Two ways to enter a prestaged round (#2276 S8-d):
  #  - JOIN (--round / --force-round named): the reviewer pass already opened
  #    this round and owns its counter (X-chain fch_scan --round N). Re-enter
  #    that exact number and advance nothing.
  #  - ADVANCE (no round named): the scanner fallback re-run after a codex
  #    exit-3 rollback. Allocate the next round and PERSIST the counter exactly
  #    as the reviewer pass does, so the fallback round is consumed against the
  #    2+1 cap. Without this a codex-unavailable review reopens round 1 on every
  #    restart and ROUND >= CAP + MAX_EXT never fires — a 4th-round path (S9-c).
  if (( ROUND_EXPLICIT == 1 )); then
    [[ -z "${ROUND:-}" && -n "${FORCE_ROUND:-}" ]] && ROUND="$FORCE_ROUND"
  else
    prestaged_advance_round
  fi
  rr_apply_extensions_used "$ROUND"

  TMP_OUT=$(mktemp) || die "mktemp failed"
  rk_load_prestaged

  FINAL_EXIT=0
  HIGH_N=0; MED_N=0; LOW_N=0

  # Checked before the reduce commits the round: a missing verdict engine halts while
  # REDUCE_COMMITTED is still false, so the counter rolls back instead of leaving a record gap.
  require_verdict_bin

  if ! ledger_cli stage --round "$ROUND" --producer "$PRESTAGED_PRODUCER" \
        --exec "$PRESTAGED_EXEC" --parser anchored --from-report "$TMP_OUT" >/dev/null 2>&1; then
    echo "run-codex-review-loop: failed to write ledger to $LEDGER" >&2
    exit 4
  fi

  # Completeness is the reducer's job (cl_round_complete_for, CPR-SSOT): a round
  # where the single staged producer is COMPLETE and in the allowed set folds; a
  # PARTIAL/ABSENT or out-of-set delta leaves its concerns open+stale. The loop
  # does not re-derive an all-producers-present gate here — scanner-alone (or
  # codex-alone) completes a review-security-shared round (#2276 S8-d).
  REDUCE_RC=0
  TALLY="$(ledger_cli reduce --round "$ROUND" 2>/dev/null)" || REDUCE_RC=$?
  if (( REDUCE_RC != 0 )) || [[ -z "$TALLY" ]] || [[ ! -f "$LEDGER" ]]; then
    echo "run-codex-review-loop: round ${ROUND} could not be folded into the ledger (reduce rc=${REDUCE_RC}); refusing to judge it from the previous round's tally" >&2
    exit 4
  fi

  for _kv in $TALLY; do
    case "$_kv" in
      open_high=*)   HIGH_N="${_kv#*=}" ;;
      open_medium=*) MED_N="${_kv#*=}" ;;
      open_low=*)    LOW_N="${_kv#*=}" ;;
    esac
  done
  [[ "$HIGH_N" =~ ^[0-9]+$ ]] || HIGH_N=0
  [[ "$MED_N"  =~ ^[0-9]+$ ]] || MED_N=0
  [[ "$LOW_N"  =~ ^[0-9]+$ ]] || LOW_N=0

  # A clean scanner report legitimately leaves the ledger header-only: nothing
  # was raised, so the round APPROVES (#2276 P4). Only guard the inconsistent
  # case — the tally claims open concerns the ledger cannot show — which would
  # otherwise be judged from a stale or lost round (#2025-class data loss).
  if (( HIGH_N + MED_N + LOW_N > 0 )) \
      && [[ -f "$LEDGER" ]] && ! grep -qE '^C[0-9]+\|' "$LEDGER"; then
    echo "run-codex-review-loop: reduce reports ${HIGH_N}/${MED_N}/${LOW_N} open concerns for round ${ROUND} but the ledger holds no concern entries; refusing to judge from an inconsistent ledger" >&2
    exit 4
  fi
  # Committed only after the sanity check: its exit 4 leaves the round unsettled, so
  # _srn_rollback restores ROUND_PREV instead of consuming a round the record has no row for.
  # shellcheck disable=SC2034  # read by round-counter.sh (srn_commits, _srn_rollback)
  REDUCE_COMMITTED=true

  dispatch_prestaged_verdict

  vs_emit "$FINAL_EXIT"
}
