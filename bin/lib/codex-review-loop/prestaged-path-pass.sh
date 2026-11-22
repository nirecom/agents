#!/usr/bin/env bash
# bin/lib/codex-review-loop/prestaged-path-pass.sh — the path-kind CC-fallback round of
# bin/run-codex-review-loop (#2478 S1): a prestaged ADVANCE counted and capped like a codex
# round, and undone whole when it does not reach the review record (S1-4). Sourced by the
# loop; reads/writes its caller-scope round, ledger and record globals. `exit` ends the process.

PP_SNAPSHOT_TAKEN=0
PP_ROUND_RECORDED=0
PP_ARCHIVE_PATH=""
PP_SNAPSHOT_DIR=""
PP_SNAPSHOT_FILES=()

# fallback_brief — the round the next fallback ADVANCE will parse, and (round >= 2) the prior
# the reviewer may speak about. Reads only; exits 0, or 4 on a corrupt counter.
fallback_brief() {
  local next
  next="$(prestaged_next_round)" || exit 4
  printf 'FALLBACK_ROUND=%s\n' "$next"
  if (( next >= 2 )) && [[ -f "$LEDGER" ]]; then
    ledger_cli render-prior || exit 4
  fi
  exit 0
}

# _pp_stage_name — the plan stage a format's fallback raw is named after.
_pp_stage_name() {
  case "$FORMAT" in
    outline-plan) printf 'outline' ;;
    detail-plan) printf 'detail' ;;
    *) printf '%s' "$FORMAT" ;;
  esac
}

# pp_round_snapshot — copy every control file this round may rewrite (the one list, SSOT);
# a file that does not exist is recorded as absent. Taken before the round-1 archive.
pp_round_snapshot() {
  local f i=0
  PP_SNAPSHOT_FILES=("$LEDGER" "$CONTROL_DIR/$LEDGER_FORMAT-unresolved-concerns.json"
    "${LEDGER%-concern-ledger.txt}-concern-carrier.md" "${LEDGER%.txt}-cap-snapshot.txt")
  PP_SNAPSHOT_DIR="$(mktemp -d "$CONTROL_DIR/.pp-snap-XXXXXX" 2>/dev/null)" \
    || die "cannot snapshot the fallback round's control files in: $CONTROL_DIR"
  for f in "${PP_SNAPSHOT_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      cp -p "$f" "$PP_SNAPSHOT_DIR/$i" || die "cannot snapshot: $f"
    fi
    i=$(( i + 1 ))
  done
  PP_SNAPSHOT_TAKEN=1
}

# pp_round_restore — EXIT-trap undo of a fallback round that was not recorded: control files
# back to the snapshot, the archive and staging files of this round removed, counter rolled back.
pp_round_restore() {
  local f i=0 failed=0
  # Without the snapshot dir a missing copy cannot be told from "absent at snapshot time".
  [[ -n "$PP_SNAPSHOT_DIR" && -d "$PP_SNAPSHOT_DIR" ]] || failed=1
  (( failed == 0 )) && for f in "${PP_SNAPSHOT_FILES[@]}"; do
    if [[ -e "$f" && ! -f "$f" ]]; then
      failed=1
    elif [[ -f "$PP_SNAPSHOT_DIR/$i" ]]; then
      cp -p "$PP_SNAPSHOT_DIR/$i" "$f" || failed=1
    else
      rm -f "$f" || failed=1
    fi
    i=$(( i + 1 ))
  done
  if (( failed == 0 )); then
    [[ -n "$PP_ARCHIVE_PATH" ]] && rm -f "$PP_ARCHIVE_PATH"
    rm -rf "$PP_SNAPSHOT_DIR"
  else
    echo "run-codex-review-loop: the fallback round ${ROUND:-?} could not be fully undone; the snapshot (${PP_SNAPSHOT_DIR}) and archive (${PP_ARCHIVE_PATH:-none}) are kept for manual recovery" >&2
  fi
  rm -f "$CONTROL_DIR/$LEDGER_FORMAT-round-${ROUND:-0}-delta-"*.txt
  REDUCE_COMMITTED=false
  # shellcheck disable=SC2034  # read by the loop's EXIT trap (settle_round_counter)
  FINAL_RC=4
  PP_SNAPSHOT_TAKEN=0
}

# pp_round_settle — the loop's EXIT-trap hook: undo an unrecorded round, else drop the snapshot.
# A row that landed although its append CLI failed keeps the round; FINAL_RC stays the verdict
# vs_emit set before the append, so the counter settles per the verdict (#2478 C1).
pp_round_settle() {
  (( PP_SNAPSHOT_TAKEN == 1 )) || return 0
  if (( PP_ROUND_RECORDED != 1 )) && [[ -n "${PP_APPEND_RUN_ID:-}" ]] && rr_round_landed; then
    echo "run-codex-review-loop: the review round row of round ${ROUND:-?} landed despite the append failure; keeping the round" >&2
    rm -rf "$PP_SNAPSHOT_DIR"
    PP_SNAPSHOT_TAKEN=0
  elif (( PP_ROUND_RECORDED != 1 )); then
    pp_round_restore
  else
    rm -rf "$PP_SNAPSHOT_DIR"
    PP_SNAPSHOT_TAKEN=0
  fi
}

# _pp_cap_precheck <ext...> — exit 2 when the round is past the cap for any given EXTENSIONS_USED.
_pp_cap_precheck() {
  local ext hdr rc
  declare -F codex_core_hard_cap_check >/dev/null || die "codex-core.sh is not loaded; cannot judge the round cap"
  for ext in "$@"; do
    [[ "$ext" =~ ^[0-9]+$ ]] || continue
    rc=0
    hdr="$(codex_core_hard_cap_check "$ROUND" "$CAP" "$ext" "$MAX_EXT" "Codex Review")" || rc=$?
    if (( rc == 2 )); then
      printf '%s\n' "$hdr" >&2
      echo "run-codex-review-loop: round cap reached for the fallback round ${ROUND}; nothing was recorded" >&2
      exit 2
    fi
    (( rc == 0 )) || die "round cap check failed (rc=${rc})"
  done
}

# run_prestaged_path_pass — one path-kind CC-fallback round (S1-3 a-j). Steps a-c persist
# nothing; any failure after the snapshot is undone by the EXIT trap (pp_round_restore).
run_prestaged_path_pass() {
  local next caller_ext="$EXT_USED" raw stage
  # Held until the EXIT trap (release_round_lock), so the snapshot, the round and its undo or
  # settle never interleave with another run (#2478 C2).
  acquire_round_lock
  next="$(prestaged_next_round)" || exit 4
  ROUND="$next"
  rr_apply_extensions_used "$ROUND"
  # The caller's count is checked too: the record derives it from rows the caller may not
  # have extended yet, and the lower budget wins.
  _pp_cap_precheck "$caller_ext" "$EXT_USED"

  pp_round_snapshot
  prestaged_advance_round
  if [[ "$ROUND" != "$next" ]]; then
    echo "run-codex-review-loop: the round moved from ${next} to ${ROUND} while the fallback was prepared; re-run --fallback-brief" >&2
    exit 4
  fi
  # The fallback reviewer is the round's only producer: a delta another producer left under
  # this round number (an earlier cycle, or a rolled-back codex run) must not be folded in.
  rm -f "$CONTROL_DIR/$LEDGER_FORMAT-round-$ROUND-delta-"*.txt

  TMP_OUT=$(mktemp) || die "mktemp failed"
  rk_load_prestaged
  stage="$(_pp_stage_name)"
  raw="$PLANS_DIR/$SID-${stage}-fallback-raw.md"
  if [[ ! "$PRESTAGED_REPORT" -ef "$raw" ]]; then
    cp -f "$PRESTAGED_REPORT" "$raw" || die "cannot keep the fallback raw at: $raw"
  fi
  if ! bash "$CRL_LIB/detect-input-error.sh" "$TMP_OUT"; then
    echo "run-codex-review-loop: the fallback report carries INPUT_ERROR (or is unreadable); the round is not counted" >&2
    exit 4
  fi
  # shellcheck disable=SC2034  # read by path_verdict (path-parse.sh)
  HEADER=""
  PATH_VERDICT_FAIL_RC=4 path_verdict

  FINAL_EXIT=0
  # shellcheck disable=SC2034  # overwritten and read by path_ledger_pass / vs_emit
  HIGH_N=0 MED_N=0 LOW_N=0
  if [[ "$VERDICT" =~ ^APPROVED($|[[:space:]]) ]]; then
    cleanup_ledger
    # shellcheck disable=SC2034  # read by round-counter.sh (srn_commits, _srn_rollback)
    REDUCE_COMMITTED=true
  else
    path_ledger_pass "$PRESTAGED_PRODUCER"
  fi
  vs_emit "$FINAL_EXIT"
}
