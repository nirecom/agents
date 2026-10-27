# shellcheck shell=bash
# bin/lib/merge-parents.sh — source-only. The bash reader of the bin/merge-parents record stream
# (#2812): the parent baseline(s) of each staged tests/ path; the gates read records only here.
# Rules R1-R7: hooks/lib/merge-parents.js. Callers run from the repo root.
#   mp_run <bin-dir> <out-file> <rel>...  one CLI call into <out-file>; rc 1 when the CLI failed
#   mp_load_file <file>                   MP_RELS / MP_INP / MP_SAME / MP_B1 / MP_B2 / MP_BASE, MP_STATE / MP_REASON
#   mp_find <rel>                         MP_I; a rel without a record gets a HEAD-only one (R1/R2/R3)
#   mp_in_parent <rel> / mp_baselines <rel>  rc 0 when some parent has it / MP_OUT_SAME, MP_OUT_B1|B2|BASE
#   mp_staged_once <bin-dir> / mp_baseline_args <rel> <dir>  pre-commit: one load / language-match flags
#   mp_note [--fallback-only]             the one HEAD-only notice line on stderr, once per load

MP_RELS=(); MP_INP=(); MP_SAME=(); MP_B1=(); MP_B2=(); MP_BASE=()
MP_STATE=""; MP_REASON=""; MP_I=""; MP_NOTED=0
MP_OUT_SAME=""; MP_OUT_B1=""; MP_OUT_B2=""; MP_OUT_BASE=""

_mp_reset() {
  MP_RELS=(); MP_INP=(); MP_SAME=(); MP_B1=(); MP_B2=(); MP_BASE=()
  MP_STATE=""; MP_REASON=""; MP_I=""; MP_NOTED=0
}

mp_run() {
  local bindir="${1:?mp_run: bin-dir}" out="${2:?mp_run: out-file}" rc=0
  shift 2
  { [[ "$#" -eq 0 ]] || printf '%s\0' "$@"; } | node "$bindir/merge-parents" >"$out" 2>/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'state\tundecidable\tmerge-parents-cli-failed\0' >"$out" 2>/dev/null || true
    return 1
  fi
  return 0
}

# _mp_oid <field> — rc 0 for "-" or a full sha1 / sha256 hex oid.
_mp_oid() {
  [[ "$1" == - || "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

# _mp_push <meta> <path> — appends one record; rc 1 when <meta> is not five valid fields.
_mp_push() {
  local tab=$'\t' rest="$1" inp same b1 b2 base
  [[ -n "$2" ]] || return 1
  inp="${rest%%"$tab"*}"; [[ "$rest" == *"$tab"* ]] || return 1; rest="${rest#*"$tab"}"
  same="${rest%%"$tab"*}"; [[ "$rest" == *"$tab"* ]] || return 1; rest="${rest#*"$tab"}"
  b1="${rest%%"$tab"*}"; [[ "$rest" == *"$tab"* ]] || return 1; rest="${rest#*"$tab"}"
  b2="${rest%%"$tab"*}"; [[ "$rest" == *"$tab"* ]] || return 1; base="${rest#*"$tab"}"
  [[ "$inp" == [01] && "$same" == [01] ]] || return 1
  _mp_oid "$b1" && _mp_oid "$b2" && _mp_oid "$base" || return 1
  [[ "$b1" != - ]] || b1=""
  [[ "$b2" != - ]] || b2=""
  [[ "$base" != - ]] || base=""
  MP_RELS+=("$2"); MP_INP+=("$inp"); MP_SAME+=("$same"); MP_B1+=("$b1"); MP_B2+=("$b2"); MP_BASE+=("$base")
}

# _mp_header <record> — MP_STATE / MP_REASON from `state<TAB><state><TAB><reason|->`; rc 1 if malformed.
_mp_header() {
  local tab=$'\t' rest
  [[ "$1" == state"$tab"*"$tab"* ]] || return 1
  rest="${1#state"$tab"}"
  MP_STATE="${rest%%"$tab"*}"
  MP_REASON="${rest#*"$tab"}"
  [[ "$MP_REASON" != - ]] || MP_REASON=""
  case "$MP_STATE" in not-merging|merging|undecidable) return 0 ;; esac
  return 1
}

mp_load_file() {
  local file="${1:?mp_load_file: file}" rec="" meta="" n=0 ok=1
  _mp_reset
  if [[ -f "$file" && -r "$file" ]]; then
    while IFS= read -r -d '' rec; do
      if [[ "$n" -eq 0 ]]; then
        _mp_header "$rec" || { ok=0; break; }
      elif (( n % 2 == 1 )); then
        meta="$rec"
      else
        _mp_push "$meta" "$rec" || { ok=0; break; }
      fi
      n=$((n + 1))
      rec=""
    done <"$file"
    # A record left without its NUL terminator, a header-less file, or a path-less record.
    [[ -z "$rec" && "$n" -gt 0 ]] && (( n % 2 == 1 )) || ok=0
  else
    ok=0
  fi
  if [[ "$ok" -eq 0 ]]; then
    _mp_reset
    MP_STATE=fallback
    MP_REASON=merge-parents-records-malformed
  fi
  return 0
}

mp_find() {
  local rel="$1" i=0 n="${#MP_RELS[@]}" h s
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${MP_RELS[$i]}" == "$rel" ]]; then MP_I="$i"; return 0; fi
    i=$((i + 1))
  done
  h="$(git rev-parse -q --verify "HEAD:$rel" 2>/dev/null)" || h=""
  s="$(git rev-parse -q --verify ":$rel" 2>/dev/null)" || s=""
  MP_RELS+=("$rel"); MP_B2+=(""); MP_BASE+=("")
  if [[ -n "$h" && "$s" == "$h" ]]; then
    MP_INP+=(1); MP_SAME+=(1); MP_B1+=("$h")
  elif [[ -n "$h" ]]; then
    MP_INP+=(1); MP_SAME+=(0); MP_B1+=("$h")
  else
    MP_INP+=(0); MP_SAME+=(0); MP_B1+=("")
  fi
  MP_I="$n"
  return 0
}

mp_in_parent() {
  mp_find "$1"
  [[ "${MP_INP[$MP_I]}" == 1 ]]
}

mp_baselines() {
  mp_find "$1"
  MP_OUT_SAME="${MP_SAME[$MP_I]}"
  MP_OUT_B1="${MP_B1[$MP_I]}"
  MP_OUT_B2="${MP_B2[$MP_I]}"
  MP_OUT_BASE="${MP_BASE[$MP_I]}"
  return 0
}

# mp_staged_once <bin-dir> — on its first call in this shell, one CLI call over every staged tests/
# path into MP_STAGED_FILE (empty when no temp file can be made), loaded and noted. The file is
# removed on EXIT; another EXIT trap set in the same shell would replace this one.
MP_STAGED_DONE=0; MP_STAGED_FILE=""
mp_staged_once() {
  local bindir="${1:?mp_staged_once: bin-dir}" rel
  local -a all=()
  [[ "$MP_STAGED_DONE" -eq 0 ]] || return 0
  MP_STAGED_DONE=1
  MP_STAGED_FILE="$(mktemp 2>/dev/null)" || MP_STAGED_FILE=""
  if [[ -z "$MP_STAGED_FILE" ]]; then
    MP_STATE=undecidable; MP_REASON=mktemp-failed; mp_note; return 0
  fi
  trap 'rm -f "$MP_STAGED_FILE"' EXIT
  while IFS= read -r -d '' rel; do all+=("$rel"); done < <(git diff --cached --name-only -z -- 'tests/' 2>/dev/null || true)
  mp_run "$bindir" "$MP_STAGED_FILE" ${all[@]+"${all[@]}"} || true
  mp_load_file "$MP_STAGED_FILE"
  mp_note
}

# mp_baseline_args <rel> <dir> — MP_ARGS: rel's baseline flags for bin/check-test-language-match.sh
# (--declaration-only, none, --head, or --head --head [--base]), the blobs extracted to
# <dir>/{head,head2,base}/<basename>; MP_COPIES: those copies. rc 1 when a blob cannot be read.
# --declaration-only is for a merge only: a normal commit keeps its --head run (and its WARN lines).
mp_baseline_args() {
  local rel="$1" dir="$2" slot oid copy
  MP_ARGS=(); MP_COPIES=()
  mp_baselines "$rel"
  if [[ "$MP_OUT_SAME" == 1 && "$MP_STATE" == merging ]]; then MP_ARGS=(--declaration-only); return 0; fi
  for slot in head head2 base; do
    case "$slot" in head) oid="$MP_OUT_B1" ;; head2) oid="$MP_OUT_B2" ;; *) oid="$MP_OUT_BASE" ;; esac
    [[ -n "$oid" && ( "$slot" != base || -n "$MP_OUT_B2" ) ]] || continue
    copy="$dir/$slot/${rel##*/}"
    mkdir -p "$dir/$slot" && git cat-file blob "$oid" >"$copy" 2>/dev/null || return 1
    MP_COPIES+=("$copy")
    if [[ "$slot" == base ]]; then MP_ARGS+=(--base "$copy"); else MP_ARGS+=(--head "$copy"); fi
  done
  return 0
}

# mp_note — notes an undecidable or fallback state; --fallback-only (a consumer handed a record file
# the producer already noted) notes only a malformed file.
mp_note() {
  [[ "$MP_NOTED" -eq 0 ]] || return 0
  case "$MP_STATE" in
    fallback) ;;
    undecidable) [[ "${1:-}" != --fallback-only ]] || return 0 ;;
    *) return 0 ;;
  esac
  MP_NOTED=1
  echo "pre-commit: merge parents ${MP_REASON:-unknown} — tests/ gates judge against HEAD only" >&2
  return 0
}
