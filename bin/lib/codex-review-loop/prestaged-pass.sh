#!/usr/bin/env bash
# bin/lib/codex-review-loop/prestaged-pass.sh — PRESTAGED (scanner fallback) pass
# for bin/run-codex-review-loop (#2276 S8-d), extracted verbatim under
# rules/coding/file-split.md Pattern A to keep the entrypoint under the 500-line
# HARD limit. Sourced by the loop: reads/writes its caller-scope round & ledger
# globals and calls die(), the round-counter/ledger helpers and
# dispatch_prestaged_verdict (all loaded before the first call). `exit` here ends
# the process, as at the original call site.

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
    acquire_round_lock
    ROUND_FILE_EXISTED=0
    ROUND_PREV=0
    if [[ -f "$ROUND_FILE" ]]; then
      ROUND_FILE_EXISTED=1
      if ! ROUND_PREV="$(read_round_file)"; then
        echo "run-codex-review-loop: round counter is corrupt: ${ROUND_FILE} (content is not a bare integer 1-999); inspect it and re-run with --force-round <N> once the correct round is known" >&2
        exit 4
      fi
    fi
    ROUND=$(( ROUND_PREV + 1 ))
    write_round_file "$ROUND"
    # Fresh cycle: no prior round counter existed, so any ledger left on disk
    # belongs to a prior terminated cycle. Archive it before staging so new
    # concerns do not reduce into stale terminal entries. Halt (exit 4) on
    # any failure: proceeding into an old terminal ledger corrupts the round
    # history more than stopping (#2256 C16 archive-or-halt).
    if (( ROUND == 1 && ROUND_FILE_EXISTED == 0 )) && [[ -f "${LEDGER:-}" ]]; then
      local _arch
      if ! _arch="$(mktemp "${PLANS_DIR}/.prev-XXXXXX" 2>/dev/null)"; then
        echo "run-codex-review-loop: cannot create archive temp; halting to avoid reducing into stale terminal ledger" >&2
        exit 4
      fi
      if ! mv -f "${LEDGER}" "$_arch"; then
        rm -f "$_arch"
        echo "run-codex-review-loop: cannot archive prior cycle ledger; halting to avoid reducing into stale terminal ledger" >&2
        exit 4
      fi
    fi
    PRESTAGED_ADVANCED=1
    release_round_lock
  fi

  TMP_OUT=$(mktemp) || die "mktemp failed"
  rk_load_prestaged

  FINAL_EXIT=0
  HIGH_N=0; MED_N=0; LOW_N=0

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

  dispatch_prestaged_verdict

  cat "$TMP_OUT"
  FINAL_RC="$FINAL_EXIT"
  exit "$FINAL_EXIT"
}
