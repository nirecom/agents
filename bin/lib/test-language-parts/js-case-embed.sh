# shellcheck shell=bash
# shellcheck disable=SC2034  # CEC_FETCH, CEC_COUNT and CEC_LAUNCH are read by cec_dispatch
# bin/lib/test-language-parts/js-case-embed.sh — the js entry's caseEmbedRules part. Source only.
# js_case_embed <op> <abs-file> [args]: dispatches the op to js-case-analyzer.js (one launch per
# op; node starts light enough to need no cache).

declare -F cec_dispatch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/case-embed-common.sh"

# _jce_count <stdout-file> — the counts of node-reporter.mjs's `<STATE>: <case>` lines (PASS and
# FAIL; SKIP counts neither); a plain-script run prints none, which leaves both empty.
_jce_count() {
  local line p=0 f=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "${line%$'\r'}" in
      "PASS: "*) p=$((p + 1)) ;;
      "FAIL: "*) f=$((f + 1)) ;;
    esac
  done <"$1"
  if [[ $((p + f)) -gt 0 ]]; then CEC_PASS="$p" CEC_FAIL="$f"; fi
}

js_case_embed() {
  local CEC_FETCH="" CEC_COUNT=_jce_count
  local -a CEC_LAUNCH=()
  crb_native_path "${BASH_SOURCE[0]%/*}/js-case-analyzer.js"
  CEC_LAUNCH=(node "$CRB_PATH")
  cec_dispatch js "$@"
}
