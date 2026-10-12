#!/usr/bin/env bash
# bin/sweep-plans/delete-passes.sh — listing, approval gate passes, and deletion.
# Source-only module of bin/sweep-plans.sh. Deletion scope: non-plan files of old,
# non-revived groups; plan / user-requested files only for groups approved in pass 2.

declare -A GATE_ROW=()       # pass 2: token -> "newest_epoch<TAB>basename:epoch,..." as shown
declare -A APPROVED_OK=()    # pass 2: group key -> 1 when approved, shown, still old, unchanged
APPROVAL_CANDIDATES=()       # "token<TAB>plan_files<TAB>user_requested_files<TAB>newest_epoch"
APPROVAL_SKIPPED=()          # "token<TAB>reason"
gate_id=""

# _candidate_line <label> <token> <indices> — one PLAN-/USER-REQUESTED-CANDIDATE line.
_candidate_line() {
  local i n=0 lo=0 hi=0
  for i in $3; do
    n=$(( n + 1 ))
    if (( n == 1 || F_MTIME[i] < lo )); then lo="${F_MTIME[i]}"; fi
    if (( F_MTIME[i] > hi )); then hi="${F_MTIME[i]}"; fi
  done
  (( n == 0 )) && return 0
  say "$1: session=$2 files=$n oldest=$(format_date "$lo") newest=$(format_date "$hi")"
}

# Per-candidate listing and class counters (every mode). One pass per group, no subshell
# unless a line is printed: format_date must keep forking the external date.
sweep_plans_list() {
  local key tok pfx i lo hi n plan ur np unk n_plan n_ur n_np n_unk newest sessions=0
  for key in "${CAND_KEYS[@]}"; do
    key_names "$key"; tok="$KEY_TOK"; pfx="$KEY_PFX"
    plan=""; ur=""; np=""; unk=""; n_plan=0; n_ur=0; n_np=0; n_unk=0; n=0; lo=0; hi=0; newest=0
    for i in ${GROUP_IDX[$key]}; do
      n=$(( n + 1 ))
      if (( n == 1 || F_MTIME[i] < lo )); then lo="${F_MTIME[i]}"; fi
      if (( F_MTIME[i] > hi )); then hi="${F_MTIME[i]}"; fi
      case "${F_CLASS[i]}" in
        plan) plan+="$i "; n_plan=$(( n_plan + 1 )) ;;
        user-requested) ur+="$i "; n_ur=$(( n_ur + 1 )) ;;
        non-plan) np+="$i "; n_np=$(( n_np + 1 )) ;;
        unknown) unk+="$i "; n_unk=$(( n_unk + 1 )) ;;
      esac
      case "${F_CLASS[i]}" in
        plan|user-requested) if (( F_MTIME[i] > newest )); then newest="${F_MTIME[i]}"; fi ;;
      esac
    done
    files_plan_candidates=$(( files_plan_candidates + n_plan ))
    files_user_requested_candidates=$(( files_user_requested_candidates + n_ur ))
    files_non_plan_candidates=$(( files_non_plan_candidates + n_np ))
    files_unknown_kept=$(( files_unknown_kept + n_unk ))
    # Without the include flag a plan / user-requested-only group is summarised by the hint line.
    if [[ "$DRY_RUN" == "1" ]] && [[ "$INCLUDE_APPROVAL" == "1" || $(( n_np + n_unk )) -gt 0 ]]; then
      say "DRY-RUN: candidate session=$pfx files=$n oldest=$(format_date "$lo") newest=$(format_date "$hi") plan=$n_plan user-requested=$n_ur non-plan=$n_np unknown=$n_unk"
      for i in $np; do say "DRY-RUN: would remove non-plan ${F_BASE[i]}"; done
      for i in $unk; do say "UNKNOWN: ${F_BASE[i]}"; done
    fi
    if [[ "$INCLUDE_APPROVAL" == "1" ]]; then
      _candidate_line PLAN-CANDIDATE "$tok" "$plan"
      _candidate_line USER-REQUESTED-CANDIDATE "$tok" "$ur"
    fi
    if [[ -n "$plan$ur" ]]; then
      sessions=$(( sessions + 1 ))
      APPROVAL_CANDIDATES+=("$tok"$'\t'"$n_plan"$'\t'"$n_ur"$'\t'"$newest")
    fi
  done
  groups_approval_candidates="$sessions"
  if [[ "$INCLUDE_APPROVAL" == "0" ]] && (( sessions > 0 )); then
    say "plan / user-requested files kept: $(( files_plan_candidates + files_user_requested_candidates )) in $sessions sessions — run /sweep-plans --include-plan-and-user-requested to review them for deletion"
  fi
}

_gate_path() {
  local p
  p="$("$SCRIPT_DIR/workflow-control-dir" --session "$GATE_SESSION" --file sweep-plans-gate.tsv "$@")" || return 1
  printf '%s' "$p"
}

# The plans dir this run resolved, physical and in node's spelling; the gate binds to it.
_gate_plans_dir() {
  local d
  d="$(cd "$PLANS_DIR" 2>/dev/null && pwd -P)" || return 1
  native_path "$d"
}

_gate_fail() {
  _printable "$1"
  printf 'ERROR: sweep-plans: %s; nothing deleted\n' "$PRINTABLE_OUT" >&2
  exit 2
}

# Pass 1: write the gate artifact for the shown candidates and print the block.
sweep_plans_gate_write() {
  local path row key tok dir
  path="$(_gate_path --for-write)" || _gate_fail "approval gate artifact path unavailable"
  dir="$(_gate_plans_dir)" || _gate_fail "approval gate artifact could not be written"
  if (( ${#APPROVAL_CANDIDATES[@]} == 0 )); then rm -f -- "$path"; return 0; fi
  local rows=""
  for key in "${CAND_KEYS[@]}"; do
    group_files "$key" plan user-requested
    [[ -n "$GF_OUT" ]] || continue
    gate_signature "$key"
    key_names "$key"
    rows+="$KEY_TOK"$'\t'"$GS_OUT"$'\n'
  done
  gate_id="$(printf '%s' "$rows" | node "$(native_path "$SCRIPT_DIR/sweep-plans/gate-artifact.js")" write "$(native_path "$path")" "$dir")" \
    || _gate_fail "approval gate artifact could not be written"
  gate_id="${gate_id//$'\r'/}"
}

sweep_plans_gate_block() {
  local row tok np nu newest
  [[ -n "$gate_id" ]] || return 0
  say "<<<APPROVAL-GATE-SP3"
  say "# gate-id: $gate_id"
  say "# Only the tokens listed below can be approved; answer with the tokens whose files to delete."
  say "# $EMPTY_PREFIX_TOKEN stands for the empty-prefix bucket (basenames that start with '-')."
  say "token"$'\t'"plan files"$'\t'"user-requested files"$'\t'"newest"
  for row in "${APPROVAL_CANDIDATES[@]}"; do
    IFS=$'\t' read -r tok np nu newest <<< "$row"
    say "$tok"$'\t'"$np"$'\t'"$nu"$'\t'"$(format_date "$newest")"
  done
  say ">>>"
}

# Pass 2, before any deletion: verify the gate, then every approved token, then consume.
sweep_plans_gate_verify() {
  local path rows line tok newest list key dir
  local -a tokens=()
  path="$(_gate_path)" || _gate_fail "approval gate artifact missing or mismatched"
  dir="$(_gate_plans_dir)" || _gate_fail "approval gate artifact missing or mismatched"
  rows="$(node "$(native_path "$SCRIPT_DIR/sweep-plans/gate-artifact.js")" verify "$(native_path "$path")" "$GATE_ID" "$dir")" \
    || _gate_fail "approval gate artifact missing or mismatched"
  while IFS=$'\t' read -r tok newest list; do
    [[ -n "$tok" ]] && GATE_ROW["$tok"]="$newest"$'\t'"$list"
  done <<< "${rows//$'\r'/}"
  [[ -f "$APPROVED_FILE" && -r "$APPROVED_FILE" ]] || _gate_fail "approved sessions file not readable: $APPROVED_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^[A-Za-z0-9_-]+$ && "$line" != "$EMPTY_PREFIX_TOKEN" ]] || [[ -z "${GATE_ROW[$line]+x}" ]]; then
      _gate_fail "approved token not shown in the gate: $line"
    fi
    tokens+=("$line")
  done < "$APPROVED_FILE"
  if [[ "$DRY_RUN" == "0" ]]; then
    rm -f -- "$path" || _gate_fail "approval gate artifact could not be consumed"
  fi
  local -A seen=()
  for tok in "${tokens[@]}"; do
    [[ -n "${seen[$tok]+x}" ]] && continue
    seen["$tok"]=1
    key="$tok"
    if [[ "$tok" == "$EMPTY_PREFIX_TOKEN" ]]; then key="$EMPTY_PREFIX_KEY"; fi
    GF_OUT=""
    if _is_candidate "$key"; then group_files "$key" plan user-requested; fi
    if [[ -z "$GF_OUT" ]]; then
      _approval_skip "$tok" not-a-candidate
      continue
    fi
    gate_signature "$key"
    if [[ "$GS_OUT" != "${GATE_ROW[$tok]}" ]]; then
      _approval_skip "$tok" changed-since-gate
    else
      APPROVED_OK["$key"]=1
    fi
  done
}

_is_candidate() { local k; for k in "${CAND_KEYS[@]}"; do [[ "$k" == "$1" ]] && return 0; done; return 1; }
_approval_skip() { APPROVAL_SKIPPED+=("$1"$'\t'"$2"); say "APPROVAL-SKIP: session=$1 reason=$2"; }

# TOCTOU re-check: a session may have written, touched or removed a matching file after
# the scan; any change to the matching name set counts as revived regardless of mtime.
# Returns 0 when revived.
_group_revived() {
  local key="$1" prefix i m f base max=0
  local -A known=()
  key_names "$key"; prefix="$KEY_PFX"
  for i in ${GROUP_IDX[$key]}; do
    known["${F_BASE[i]}"]=1
    [[ -e "${F_PATH[i]}" ]] || return 0
    m="$(file_mtime "${F_PATH[i]}")"; [[ "$m" =~ ^[0-9]+$ ]] || m="$now_epoch"
    if (( m > max )); then max="$m"; fi
  done
  # prefix="" -> -name "-*": every '-' basename, narrowed to the #847 allowlist (portable GNU/BSD find).
  while IFS= read -r -d '' f; do
    base="${f##*/}"
    if [[ "$key" == "$EMPTY_PREFIX_KEY" && ! "$base" =~ $EMPTY_PREFIX_ALLOW_RE ]]; then continue; fi
    [[ -n "${known[$base]:-}" ]] || return 0
    m="$(file_mtime "$f")"; [[ "$m" =~ ^[0-9]+$ ]] || m="$now_epoch"
    if (( m > max )); then max="$m"; fi
  done < <(find "$PLANS_DIR" -maxdepth 1 -mindepth 1 -type f -name "${prefix}-*" -print0 2>/dev/null)
  (( max >= threshold_epoch ))
}

_remove_file() {
  if rm -f -- "${F_PATH[$1]}" 2>/dev/null; then
    files_removed=$(( files_removed + 1 ))
    case "${F_CLASS[$1]}" in
      plan) files_plan_removed=$(( files_plan_removed + 1 )) ;;
      user-requested) files_user_requested_removed=$(( files_user_requested_removed + 1 )) ;;
    esac
    return 0
  fi
  errors+=("rm-failed:${F_PATH[$1]}")
  return 1
}

sweep_plans_delete() {
  local key i classes any idx
  for key in "${CAND_KEYS[@]}"; do
    classes="non-plan"
    if [[ -n "${APPROVED_OK[$key]+x}" ]]; then classes="non-plan plan user-requested"; fi
    if [[ "$DRY_RUN" == "1" ]]; then
      if [[ -n "${APPROVED_OK[$key]+x}" ]]; then
        group_files "$key" plan user-requested
        for i in $GF_OUT; do
          say "DRY-RUN: would remove ${F_CLASS[i]} ${F_BASE[i]}"
        done
      fi
      continue
    fi
    # shellcheck disable=SC2086 # classes is a word list
    group_files "$key" $classes
    idx="$GF_OUT"
    [[ -n "$idx" ]] || continue
    if _group_revived "$key"; then
      groups_skipped_revived=$(( groups_skipped_revived + 1 ))
      key_names "$key"
      printf 'WARN: session %s touched since scan; skipping (revived)\n' "$KEY_PFX" >&2
      continue
    fi
    any=0
    for i in $idx; do
      if _remove_file "$i"; then any=1; fi
    done
    if (( any == 1 )); then groups_removed=$(( groups_removed + 1 )); fi
  done
}
