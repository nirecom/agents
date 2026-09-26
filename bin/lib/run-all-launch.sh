#!/usr/bin/env bash
# run_all_exec <script> <out> <err> — per-extension test dispatch for tests/run-all.sh
# (*.Tests.ps1 → pwsh/Pester, test_*.py → uv/pytest, else bash); returns the child rc,
# 77 (SKIP) when pwsh/uv is absent. Contract: docs/architecture/tests/run-all-parallelism.md.

case "${BASH_SOURCE[0]}" in
  */*) RUN_ALL_LAUNCH_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RUN_ALL_LAUNCH_DIR="." ;;
esac

run_all_exec() {
  local script="$1" out="$2" err="$3" native rto
  local -a tmo=()
  rto="$RUN_ALL_LAUNCH_DIR/../run-with-timeout.sh"
  [[ -f "$rto" ]] && tmo=(bash "$rto" 180)
  native="$script"
  case "$script" in
    *.Tests.ps1)
      if ! command -v pwsh >/dev/null 2>&1; then
        printf 'SKIP: pwsh not on PATH\n' >"$out"; return 77
      fi
      command -v cygpath >/dev/null 2>&1 && native="$(cygpath -m "$script")"
      ${tmo[@]+"${tmo[@]}"} pwsh -NoProfile -Command "Invoke-Pester -Path '${native//\'/\'\'}' -CI" \
        >"$out" 2>"$err" </dev/null ;;
    */test_*.py|test_*.py)
      if ! command -v uv >/dev/null 2>&1; then
        printf 'SKIP: uv not on PATH\n' >"$out"; return 77
      fi
      command -v cygpath >/dev/null 2>&1 && native="$(cygpath -m "$script")"
      # --no-project: the repo has no pyproject, so keep uv from searching for or creating one.
      ${tmo[@]+"${tmo[@]}"} uv run --no-project --with pytest pytest -q "$native" \
        >"$out" 2>"$err" </dev/null ;;
    *)
      bash "$script" >"$out" 2>"$err" </dev/null ;;
  esac
}
