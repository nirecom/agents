#!/usr/bin/env bash
# bin/sweep-plans/discover.sh — scan, group, classify and age the PLANS_DIR entries.
# Source-only module of bin/sweep-plans.sh; reads PLANS_DIR, SWEEP_AGE_DAYS, SCRIPT_DIR.

# Group discovery walks depth-1 files under PLANS_DIR and groups them by session-id
# prefix: YYYYMMDD-HHMMSS, UUID, <epoch>-<pid>, or empty (basename starts with '-').
# Bash rejects empty-string array subscripts, so the empty-prefix bucket is keyed by
# EMPTY_PREFIX_KEY ('@' never appears in a valid prefix, so it cannot collide).
EMPTY_PREFIX_KEY="__empty@@__"
EMPTY_PREFIX_TOKEN="@empty"

# #847 guard — SSOT for which hyphen-prefixed basenames may enter the empty-prefix
# bucket: a lowercase-kebab stem plus one known machine extension. Anything else is
# left on disk and counted in files_skipped_unrecognized; an unknown shape is never deleted.
EMPTY_PREFIX_ALLOW_RE='^-[a-z0-9]+([._-][a-z0-9]+)*\.(md|txt|json|jsonl|log|built|tmp|tsv|err|out|status|patch)$'
SESSION_PREFIX_RE='^([0-9]{8}-[0-9]{6}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9]{10}-[0-9]+)-'

# Per-file arrays, indexed by scan order.
F_PATH=(); F_KEY=(); F_BASE=(); F_MTIME=(); F_CLASS=()
declare -A GROUP_IDX=()      # group key -> space-separated file indices
CAND_KEYS=()                 # old groups, sorted
classifier_failed=0

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

format_date() {
  date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null || printf '%s' "$1"
}

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# key_names <key> — sets KEY_PFX (basename prefix) and KEY_TOK (approval token); no subshell.
key_names() {
  if [[ "$1" == "$EMPTY_PREFIX_KEY" ]]; then KEY_PFX=""; KEY_TOK="$EMPTY_PREFIX_TOKEN"; else KEY_PFX="$1"; KEY_TOK="$1"; fi
}

# One find for every mtime (GNU -printf); a find without -printf falls back to stat per file.
_scan_records() {
  if [[ "$1" == "1" ]]; then
    find "$PLANS_DIR" -maxdepth 1 -mindepth 1 -type f -printf '%T@\t%p\0' 2>/dev/null
  else
    find "$PLANS_DIR" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null
  fi
}

sweep_plans_scan() {
  local f base key m rec bulk=0
  if find "$PLANS_DIR" -maxdepth 0 -printf '' >/dev/null 2>&1; then bulk=1; fi
  while IFS= read -r -d '' rec; do
    if [[ "$bulk" == "1" ]]; then
      m="${rec%%$'\t'*}"; m="${m%%.*}"; f="${rec#*$'\t'}"
    else
      m=""; f="$rec"
    fi
    scanned=$(( scanned + 1 ))
    base="${f##*/}"
    if [[ "$base" =~ $SESSION_PREFIX_RE ]]; then
      key="${BASH_REMATCH[1]}"
    elif [[ "$base" == -* ]]; then
      if [[ ! "$base" =~ $EMPTY_PREFIX_ALLOW_RE ]]; then
        files_skipped_unrecognized=$(( files_skipped_unrecognized + 1 ))
        continue
      fi
      key="$EMPTY_PREFIX_KEY"
    else
      continue
    fi
    if [[ "$bulk" == "0" ]]; then m="$(file_mtime "$f")"; fi
    # Unparsable/unavailable mtime reads as "now", so the group counts as young.
    [[ "$m" =~ ^[0-9]+$ ]] || m="$now_epoch"
    GROUP_IDX["$key"]+="${#F_PATH[@]} "
    F_PATH+=("$f"); F_KEY+=("$key"); F_BASE+=("$base"); F_MTIME+=("$m")
  done < <(_scan_records "$bulk")
}

_bridge_input() {
  local i
  local -a args=()
  for i in "${!F_PATH[@]}"; do
    key_names "${F_KEY[i]}"
    args+=("$KEY_PFX" "${F_BASE[i]}")
  done
  if (( ${#args[@]} > 0 )); then printf '%s\0' "${args[@]}"; fi
}

_classifier_unavailable() {
  local i
  classifier_failed=1
  for i in "${!F_PATH[@]}"; do F_CLASS[i]="unknown"; done
  printf 'WARN: sweep-plans: retention classifier unavailable (%s); keeping every plan, user-requested and non-plan file\n' "$1" >&2
}

# One bridge call for every scanned file; any malformed answer keeps everything.
sweep_plans_classify() {
  local n="${#F_PATH[@]}" out words=() w bridge="$SCRIPT_DIR/sweep-plans/retention-class.js"
  [[ "$n" -eq 0 ]] && return 0
  if ! command -v node >/dev/null 2>&1; then _classifier_unavailable "node not found"; return 0; fi
  if ! out="$(_bridge_input | node "$(native_path "$bridge")" 2>/dev/null)"; then
    _classifier_unavailable "bridge exited non-zero"; return 0
  fi
  out="${out//$'\r'/}"
  [[ -n "$out" ]] && mapfile -t words <<< "$out"
  if [[ "${#words[@]}" -ne "$n" ]]; then
    _classifier_unavailable "bridge answered ${#words[@]} lines for $n files"; return 0
  fi
  for w in "${words[@]}"; do
    case "$w" in
      plan|user-requested|non-plan|unknown) ;;
      *) _classifier_unavailable "bridge answered an unexpected word"; return 0 ;;
    esac
  done
  F_CLASS=("${words[@]}")
}

# Groups whose newest member is older than the threshold become candidates (any class).
sweep_plans_select() {
  local key i max
  threshold_epoch=$(( now_epoch - SWEEP_AGE_DAYS * 86400 ))
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    max=0
    for i in ${GROUP_IDX[$key]}; do
      (( F_MTIME[i] > max )) && max="${F_MTIME[i]}"
    done
    if (( max >= threshold_epoch )); then
      groups_skipped_young=$(( groups_skipped_young + 1 ))
      continue
    fi
    groups_candidates=$(( groups_candidates + 1 ))
    CAND_KEYS+=("$key")
  done < <(printf '%s\n' "${!GROUP_IDX[@]}" | LC_ALL=C sort)
}

# group_files <key> <class...> — sets GF_OUT to the indices of the group's files in any of the classes.
group_files() {
  local key="$1" i c; shift
  GF_OUT=""
  for i in ${GROUP_IDX[$key]-}; do
    for c in "$@"; do
      if [[ "${F_CLASS[i]}" == "$c" ]]; then GF_OUT+="$i "; break; fi
    done
  done
}

# gate_signature <key> — sets GS_OUT to "newest_epoch<TAB>basename:epoch,..." over the group's
# plan and user-requested files only, so a non-plan deletion between the passes never changes it.
gate_signature() {
  local i newest=0 list
  local -a pairs=()
  group_files "$1" plan user-requested
  for i in $GF_OUT; do
    pairs+=("${F_BASE[i]}:${F_MTIME[i]}")
    if (( F_MTIME[i] > newest )); then newest="${F_MTIME[i]}"; fi
  done
  list="$(printf '%s\n' "${pairs[@]}" | LC_ALL=C sort | paste -sd, -)"
  GS_OUT="$newest"$'\t'"$list"
}
