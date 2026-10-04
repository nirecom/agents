# shellcheck shell=bash
# bin/lib/test-language-registry.sh — bash side of the test-language registry. Source only.
# Reads `node bin/test-language-registry --format shell` once per (CLI, table) into arrays and
# answers which language a test file is, which files a condition covers, and how a language's
# parts and suites are reached. Conditions are decided by an entry's fields, never by its id.
# Works on bash 3.2: indexed arrays only, no declare (a sourcing function would make them local).

_tlr_dir="${BASH_SOURCE[0]}"
case "$_tlr_dir" in */*) _tlr_dir="${_tlr_dir%/*}" ;; *) _tlr_dir=. ;; esac
TLR_REPO_ROOT="$(cd "$_tlr_dir/../.." && pwd)"
TLR_REGISTRY_DIR="$TLR_REPO_ROOT/hooks/lib"
_TLR_SELF_CLI="$TLR_REPO_ROOT/bin/test-language-registry"

if [ -z "${_TLR_ARRAYS_INIT+x}" ]; then
  _TLR_ARRAYS_INIT=1
  TLR_LOADED_KEY=""
  _TLR_E_ID=(); _TLR_E_ST=(); _TLR_E_SELF=()
  _TLR_P_ID=(); _TLR_P_PAT=(); _TLR_P_GLOB=()
  _TLR_M_ID=(); _TLR_M_ST=(); _TLR_M_GLOB=()
  _TLR_F_KEY=(); _TLR_F_VAL=()
  _TLR_A_ID=(); _TLR_A_KIND=(); _TLR_A_VAL=()
fi

_tlr_err() { printf '[test-language-registry] %s\n' "$1" >&2; }

# tlr_load [<table.json>] — a no-op when this CLI already loaded this table (works without node).
tlr_load() {
  local file="${1:-}" key out rc kind a b c i st
  key="$_TLR_SELF_CLI|$file"
  [ -n "$TLR_LOADED_KEY" ] && [ "$TLR_LOADED_KEY" = "$key" ] && return 0
  if ! command -v node >/dev/null 2>&1; then
    _tlr_err "node not on PATH; cannot read ${file:-the registry table}"
    return 1
  fi
  local cli="$_TLR_SELF_CLI"
  command -v cygpath >/dev/null 2>&1 && cli="$(cygpath -m "$cli")"
  rc=0
  if [ -n "$file" ]; then
    out="$(node "$cli" --format shell --file "$file" 2>&1)" || rc=$?
  else
    out="$(node "$cli" --format shell 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    _tlr_err "cannot load ${file:-the registry table} (rc=$rc): ${out%%$'\n'*}"
    return 1
  fi
  TLR_LOADED_KEY=""
  _TLR_E_ID=(); _TLR_E_ST=(); _TLR_E_SELF=()
  _TLR_P_ID=(); _TLR_P_PAT=(); _TLR_P_GLOB=()
  _TLR_M_ID=(); _TLR_M_ST=(); _TLR_M_GLOB=()
  _TLR_F_KEY=(); _TLR_F_VAL=()
  _TLR_A_ID=(); _TLR_A_KIND=(); _TLR_A_VAL=()
  TLR_HEADER_MAX_LINES=""; TLR_TABLE_DRIVEN_FALLBACK=""
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      headerMaxLines) TLR_HEADER_MAX_LINES="$a" ;;
      tableDrivenFallbackEntry) TLR_TABLE_DRIVEN_FALLBACK="$a" ;;
      entry) _TLR_E_ID+=("$a"); _TLR_E_ST+=("$b"); _TLR_E_SELF+=("$c") ;;
      pattern) _TLR_P_ID+=("$a"); _TLR_P_PAT+=("$b") ;;
      glob) _TLR_P_GLOB+=("$b") ;;
      field) _TLR_F_KEY+=("$a|$b"); _TLR_F_VAL+=("$c") ;;
      arg) _TLR_A_ID+=("$a"); _TLR_A_KIND+=("$b"); _TLR_A_VAL+=("$c") ;;
    esac
  done <<<"$out"
  if [ -z "$TLR_HEADER_MAX_LINES" ] || [ "${#_TLR_E_ID[@]}" -eq 0 ] || [ "${#_TLR_P_PAT[@]}" -ne "${#_TLR_P_GLOB[@]}" ]; then
    _tlr_err "malformed shell dump from $cli"
    return 1
  fi
  # Match order: supported entries first, then table order.
  for st in supported recognized-only; do
    i=0
    while [ "$i" -lt "${#_TLR_P_ID[@]}" ]; do
      if [ "$(_tlr_status_of "${_TLR_P_ID[$i]}")" = "$st" ]; then
        _TLR_M_ID+=("${_TLR_P_ID[$i]}"); _TLR_M_ST+=("$st"); _TLR_M_GLOB+=("${_TLR_P_GLOB[$i]}")
      fi
      i=$((i + 1))
    done
  done
  TLR_LOADED_KEY="$key"
  return 0
}

_tlr_status_of() {
  local i=0
  while [ "$i" -lt "${#_TLR_E_ID[@]}" ]; do
    [ "${_TLR_E_ID[$i]}" = "$1" ] && { printf '%s' "${_TLR_E_ST[$i]}"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# _tlr_get <id> <field> — sets _TLR_V; rc 1 when the entry lacks the field (null).
_tlr_get() {
  local i=0 k="$1|$2"
  _TLR_V=""
  while [ "$i" -lt "${#_TLR_F_KEY[@]}" ]; do
    if [ "${_TLR_F_KEY[$i]}" = "$k" ]; then _TLR_V="${_TLR_F_VAL[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# tlr_field <id> <field> — the value, or an empty line for null.
tlr_field() {
  _tlr_get "$1" "$2" || true
  printf '%s\n' "$_TLR_V"
}

# tlr_match <basename-or-path> — sets TLR_ID / TLR_STATUS; rc 1 when no entry matches.
tlr_match() {
  local name="${1##*/}" i=0
  TLR_ID=""; TLR_STATUS=""
  while [ "$i" -lt "${#_TLR_M_GLOB[@]}" ]; do
    # shellcheck disable=SC2053 # the glob is the table's converted pattern
    if [[ "$name" == ${_TLR_M_GLOB[$i]} ]]; then
      TLR_ID="${_TLR_M_ID[$i]}"; TLR_STATUS="${_TLR_M_ST[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# tlr_stem <name> — the name without its entry's nameStrip; unchanged when nothing matches.
tlr_stem() {
  local name="$1" id st pre suf
  id="${TLR_ID:-}"; st="${TLR_STATUS:-}"
  if ! tlr_match "$name"; then
    TLR_ID="$id"; TLR_STATUS="$st"
    printf '%s\n' "$name"
    return 0
  fi
  _tlr_get "$TLR_ID" nameStrip.prefix || true
  pre="$_TLR_V"
  _tlr_get "$TLR_ID" nameStrip.suffix || true
  suf="$_TLR_V"
  TLR_ID="$id"; TLR_STATUS="$st"
  case "$name" in
    "$pre"*"$suf") [ "${#name}" -gt $((${#pre} + ${#suf})) ] && name="${name#"$pre"}" && name="${name%"$suf"}" ;;
  esac
  printf '%s\n' "$name"
}

# tlr_comment_prefix <path> — header.commentPrefix of the file's entry; a file no entry (or
# no header) covers takes tableDrivenFallbackEntry's. Leaves TLR_ID / TLR_STATUS unchanged.
# Also sets TLR_COMMENT_PREFIX, so a per-file loop can skip the command substitution.
tlr_comment_prefix() {
  local id="${TLR_ID:-}" st="${TLR_STATUS:-}" hit=""
  tlr_match "$1" && _tlr_get "$TLR_ID" header.commentPrefix && hit="$_TLR_V"
  [ -n "$hit" ] || { _tlr_get "$TLR_TABLE_DRIVEN_FALLBACK" header.commentPrefix || true; hit="$_TLR_V"; }
  TLR_ID="$id"; TLR_STATUS="$st"
  # shellcheck disable=SC2034
  TLR_COMMENT_PREFIX="$hit"
  printf '%s\n' "$hit"
}

# _tlr_cond <condition> <entry-index> — rc 0 when the entry meets the condition, 2 when unknown.
_tlr_cond() {
  local id="${_TLR_E_ID[$2]}" st="${_TLR_E_ST[$2]}"
  case "$1" in
    supported) [ "$st" = supported ] ;;
    recognized-only) [ "$st" = recognized-only ] ;;
    case-marker) [ "$st" = supported ] && _tlr_get "$id" caseMarkerReader.file ;;
    table-driven) _tlr_get "$id" tableDrivenDetector.file ;;
    helper-library) [ "$st" = supported ] && _tlr_get "$id" helperLibrary.path ;;
    *) _tlr_err "unknown condition: $1"; return 2 ;;
  esac
}

# _tlr_rows <condition> <pattern|glob> — that column for every entry meeting the condition.
_tlr_rows() {
  local e=0 i rc
  while [ "$e" -lt "${#_TLR_E_ID[@]}" ]; do
    rc=0; _tlr_cond "$1" "$e" || rc=$?
    [ "$rc" -eq 2 ] && return 2
    if [ "$rc" -eq 0 ]; then
      i=0
      while [ "$i" -lt "${#_TLR_P_ID[@]}" ]; do
        if [ "${_TLR_P_ID[$i]}" = "${_TLR_E_ID[$e]}" ]; then
          if [ "$2" = pattern ]; then printf '%s\n' "${_TLR_P_PAT[$i]}"; else printf '%s\n' "${_TLR_P_GLOB[$i]}"; fi
        fi
        i=$((i + 1))
      done
    fi
    e=$((e + 1))
  done
}

# tlr_ids <condition> — the ids of the entries meeting the condition, in table order.
tlr_ids() {
  local e=0 rc
  while [ "$e" -lt "${#_TLR_E_ID[@]}" ]; do
    rc=0; _tlr_cond "$1" "$e" || rc=$?
    [ "$rc" -eq 2 ] && return 2
    [ "$rc" -eq 0 ] && printf '%s\n' "${_TLR_E_ID[$e]}"
    e=$((e + 1))
  done
  return 0
}

tlr_patterns() { _tlr_rows "$1" pattern; }
tlr_globs() { _tlr_rows "$1" glob; }

# tlr_list_dir <dir> <condition> — files directly in <dir>: entry order, then name; each once.
# Line output; tlr_list_dir_into fills TLR_LIST instead, safe for names holding LF.
tlr_list_dir() {
  tlr_list_dir_into "$@" || return
  [ "${#TLR_LIST[@]}" -eq 0 ] || printf '%s\n' "${TLR_LIST[@]}"
}
tlr_list_dir_into() {
  local dir="$1" e=0 i rc pat n f seen=$'\n' opts IFS=''
  TLR_LIST=()
  # A table `*` is one or more of any character, a leading dot included (a dot-prefixed test name still matches).
  opts="$(shopt -p extglob dotglob)" || true
  shopt -s extglob dotglob
  while [ "$e" -lt "${#_TLR_E_ID[@]}" ]; do
    rc=0; _tlr_cond "$2" "$e" || rc=$?
    if [ "$rc" -eq 2 ]; then eval "$opts"; return 2; fi
    if [ "$rc" -eq 0 ]; then
      pat=""; n=0; i=0
      while [ "$i" -lt "${#_TLR_P_ID[@]}" ]; do
        if [ "${_TLR_P_ID[$i]}" = "${_TLR_E_ID[$e]}" ]; then
          pat="${pat:+$pat|}${_TLR_P_GLOB[$i]}"; n=$((n + 1))
        fi
        i=$((i + 1))
      done
      [ "$n" -gt 1 ] && pat="@($pat)"
      for f in "$dir"/$pat; do
        [ -f "$f" ] || continue
        case "$seen" in *$'\n'"$f"$'\n'*) continue ;; esac
        seen="$seen$f"$'\n'
        TLR_LIST+=("$f")
      done
    fi
    e=$((e + 1))
  done
  eval "$opts"
  return 0
}

# tlr_find <root> <condition> — every file under <root> matching the condition's globs.
tlr_find() {
  local g args=() rc=0 globs
  globs="$(tlr_globs "$2")" || return 2
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    [ "${#args[@]}" -gt 0 ] && args+=(-o)
    args+=(-name "$g")
  done <<<"$globs"
  [ "${#args[@]}" -gt 0 ] || return 0
  find "$1" -type f \( "${args[@]}" \) 2>/dev/null || rc=$?
  return "$rc"
}

# tlr_call_part <id> <field> <args...> — call the entry's part; rc 70 when it cannot be reached.
tlr_call_part() {
  local id="$1" fld="$2" file fn
  shift 2
  if ! _tlr_get "$id" "$fld.file"; then _tlr_err "entry $id has no $fld"; return 70; fi
  file="$_TLR_V"
  _tlr_get "$id" "$fld.function" || true
  fn="$_TLR_V"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    if [ ! -f "$TLR_REPO_ROOT/$file" ]; then _tlr_err "$id.$fld: part file missing: $file"; return 70; fi
    # shellcheck disable=SC1090 # the part file is named by the table
    . "$TLR_REPO_ROOT/$file"
    if ! declare -F "$fn" >/dev/null 2>&1; then _tlr_err "$id.$fld: $file does not define $fn"; return 70; fi
  fi
  "$fn" "$@"
}

# tlr_suite_root <id> <file> — nearest directory up from <file> holding launch.suiteRootMarker,
# stopping at TLR_REPO_ROOT; rc 1 when none.
tlr_suite_root() {
  local marker d
  _tlr_get "$1" launch.suiteRootMarker || return 1
  marker="$_TLR_V"
  case "$2" in /* | [A-Za-z]:/*) d="$2" ;; *) d="$PWD/$2" ;; esac
  d="${d%/*}"
  while [ -n "$d" ]; do
    if [ -f "$d/$marker" ]; then printf '%s\n' "$d"; return 0; fi
    [ "$d" = "$TLR_REPO_ROOT" ] && return 1
    case "$d" in */*) d="${d%/*}" ;; *) return 1 ;; esac
  done
  return 1
}

# tlr_exec_plain <file> <out> <err> — fallback when bin/lib/run-all-launch.sh is absent: runs <file>
# only when its supported entry's whole launch is a bare `bash {path}`; else rc 78, not launched.
tlr_exec_plain() {
  local i=0 argv="" unit=""
  RUN_ALL_EXEC_LAUNCHED=0
  if tlr_match "$1" && [ "$TLR_STATUS" = supported ] && ! _tlr_get "$TLR_ID" launch.requires && ! _tlr_get "$TLR_ID" launch.timeoutSeconds; then
    _tlr_get "$TLR_ID" launch.unit && unit="$_TLR_V"
    while [ "$i" -lt "${#_TLR_A_ID[@]}" ]; do
      [ "${_TLR_A_ID[$i]}" = "$TLR_ID" ] && argv="$argv|${_TLR_A_KIND[$i]}:${_TLR_A_VAL[$i]}"
      i=$((i + 1))
    done
  fi
  if [ "$unit" = file ] && [ "$argv" = "|command:bash|command:{path}" ]; then
    RUN_ALL_EXEC_LAUNCHED=1
    bash "$1" >"$2" 2>"$3" </dev/null
    return
  fi
  printf 'UNSUPPORTED: %s (language: %s; launcher library not found)\n' "$1" "${TLR_ID:-unknown}" >"$2"
  return 78
}

# tlr_dedupe_suites — stdin file list; one file per (suite entry, suite root), first by name,
# at the group's first position. Other files, and suite files without a root, pass through.
# tlr_dedupe_suites_into <file...> fills TLR_LIST instead, safe for names holding LF.
tlr_dedupe_suites() {
  local f args=()
  while IFS= read -r f; do args+=("$f"); done
  tlr_dedupe_suites_into ${args[@]+"${args[@]}"}
  [ "${#TLR_LIST[@]}" -eq 0 ] || printf '%s\n' "${TLR_LIST[@]}"
}
tlr_dedupe_suites_into() {
  local lines=() keys=() gk=() gr=() f k i j root LC_ALL=C
  TLR_LIST=()
  for f in "$@"; do
    [ -n "$f" ] || continue
    k=""
    if tlr_match "$f" && _tlr_get "$TLR_ID" launch.unit && [ "$_TLR_V" = suite ] && root="$(tlr_suite_root "$TLR_ID" "$f")"; then
      k="$TLR_ID|$root"
      j=0
      while [ "$j" -lt "${#gk[@]}" ] && [ "${gk[$j]}" != "$k" ]; do j=$((j + 1)); done
      if [ "$j" -eq "${#gk[@]}" ]; then gk+=("$k"); gr+=("$f")
      elif [[ "$f" < "${gr[$j]}" ]]; then gr[$j]="$f"; fi
    fi
    lines+=("$f"); keys+=("$k")
  done
  i=0
  while [ "$i" -lt "${#lines[@]}" ]; do
    k="${keys[$i]}"
    if [ -z "$k" ]; then TLR_LIST+=("${lines[$i]}"); else
      j=0
      while [ "$j" -lt "${#gk[@]}" ] && [ "${gk[$j]}" != "$k" ]; do j=$((j + 1)); done
      if [ "$j" -lt "${#gk[@]}" ] && [ -n "${gr[$j]}" ]; then TLR_LIST+=("${gr[$j]}"); gr[$j]=""; fi
    fi
    i=$((i + 1))
  done
}
