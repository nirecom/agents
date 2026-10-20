# shellcheck shell=bash
# shellcheck disable=SC2034  # CEC_FETCH, CEC_COUNT and CEC_LAUNCH are read by cec_dispatch
# bin/lib/test-language-parts/pester-case-embed.sh — the pester entry's caseEmbedRules part. Source only.
# pester_case_embed <op> <abs-file> [args]: dispatches the op to pester-case-analyzer.ps1.
# A pwsh start is slow, so with CASE_EMBED_CACHE_DIR set the first op launches the analyzer's
# `all` once and later ops for the same (abs path, content) read its cache file; without it
# every op launches the analyzer. Both give the same answers.

declare -F cec_dispatch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/case-embed-common.sh"

# _pce_block <all-output> <op> — sets CEC_OUT to the op's OP block. rc 1 when the block is
# missing or the analyzer marked the op failed.
_pce_block() {
  local line in=0 found=0 tab=$'\t'
  local -a body=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" == "OP$tab"* ]]; then
      in=0
      [[ "$line" == "OP$tab$2" ]] && { in=1; found=1; }
      [[ "$line" == "OP$tab$2$tab"* ]] && return 1
      continue
    fi
    [[ "$in" -eq 1 && -n "$line" ]] && body+=("$line")
  done <<<"$1"
  [[ "$found" -eq 1 ]] || return 1
  CEC_OUT=""
  [[ "${#body[@]}" -eq 0 ]] || CEC_OUT="$(printf '%s\n' "${body[@]}")"
}

# _pce_fetch <id> <op> <abs> — CEC_OUT for the op, through the cache file when CASE_EMBED_CACHE_DIR
# names a directory. The cache keeps one file: a KEY line (abs path and cksum), then `all`'s output.
_pce_fetch() {
  local id="$1" op="$2" abs="$3" dir="${CASE_EMBED_CACHE_DIR:-}" cache key sum all="" tab=$'\t'
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    cec_analyzer_args "$id" "$op"
    cec_launch "$op" "$abs" ${CEC_ARGS[@]+"${CEC_ARGS[@]}"}
    return
  fi
  cache="$dir/pester-case-embed.cache"
  sum="$(cksum <"$abs")" || return 1
  key="KEY$tab$abs$tab$sum"
  if [[ -f "$cache" ]]; then
    all="$(<"$cache")"
    [[ "${all%%$'\n'*}" == "$key" ]] || all=""
  fi
  if [[ -z "$all" ]]; then
    cec_helper_path "$id"
    cec_launch all "$abs" "$CEC_HELPER" || return 1
    all="$key"$'\n'"$CEC_OUT"
    if ! { printf '%s\n' "$all" >"$cache.$$" && mv -f "$cache.$$" "$cache"; }; then rm -f "$cache.$$"; fi
  fi
  _pce_block "${all#*$'\n'}" "$op"
}

# _pce_count <stdout-file> — the counts from Pester's closing `Tests Passed: N, Failed: M, ...` line.
_pce_count() { cec_count_line "$1" 'Tests Passed: ([0-9]+), Failed: ([0-9]+)'; }

pester_case_embed() {
  local CEC_FETCH=_pce_fetch CEC_COUNT=_pce_count
  local -a CEC_LAUNCH=()
  crb_native_path "${BASH_SOURCE[0]%/*}/pester-case-analyzer.ps1"
  CEC_LAUNCH=(pwsh -NoProfile -NonInteractive -File "$CRB_PATH")
  cec_dispatch pester "$@"
}
