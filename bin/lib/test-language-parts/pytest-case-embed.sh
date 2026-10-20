# shellcheck shell=bash
# shellcheck disable=SC2034  # CEC_FETCH, CEC_COUNT and CEC_LAUNCH are read by cec_dispatch
# bin/lib/test-language-parts/pytest-case-embed.sh — the pytest entry's caseEmbedRules part. Source only.
# pytest_case_embed <op> <abs-file> [args]: dispatches the op to pytest-case-analyzer.py (one
# launch per op; `uv run --no-project python` starts light enough to need no cache).

declare -F cec_dispatch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/case-embed-common.sh"

# _pyce_count <stdout-file> — the counts from pytest's closing `... N passed ... in Xs` line
# (`-q`); a word that is absent counts 0, a run with no such line leaves both empty.
_pyce_count() {
  local line p f re_sum='[0-9]+ (passed|failed|errors?|skipped|deselected|xfailed|xpassed).* in [0-9.]+s'
  local re_p='([0-9]+) passed' re_f='([0-9]+) failed' re_e='([0-9]+) errors?'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re_sum ]] || continue
    p=0 f=0
    [[ "$line" =~ $re_p ]] && p="${BASH_REMATCH[1]}"
    [[ "$line" =~ $re_f ]] && f="${BASH_REMATCH[1]}"
    [[ "$line" =~ $re_e ]] && f=$((f + BASH_REMATCH[1]))
    CEC_PASS="$p" CEC_FAIL="$f"
  done <"$1"
}

pytest_case_embed() {
  local CEC_FETCH="" CEC_COUNT=_pyce_count
  local -a CEC_LAUNCH=()
  crb_native_path "${BASH_SOURCE[0]%/*}/pytest-case-analyzer.py"
  CEC_LAUNCH=(uv run --no-project python "$CRB_PATH")
  cec_dispatch pytest "$@"
}
