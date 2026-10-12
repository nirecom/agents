# shellcheck shell=bash disable=SC2034
# bin/lib/test-language-registry-plain.sh — tlr_exec_plain; sourced by bin/lib/test-language-registry.sh.
# tlr_exec_plain <file> <out> <err> — the fallback when bin/lib/run-all-launch.sh is absent: runs <file>
# only when its supported entry is a bare `bash {path}` file launch (no requires, wrapper or prepare),
# with no timeout; sets RUN_ALL_EXEC_STATE from the rc. Not launched otherwise: another supported entry
# is rc 2 / FAIL (a run must not pass over a test it was meant to run), the rest rc 78 / UNSUPPORTED.
tlr_exec_plain() {
  local i=0 argv="" unit="" rc=0 lpath="$1" supported=0
  # A relative path starting with '-' would read as a bash option.
  case "$lpath" in -*) lpath="./$lpath" ;; esac
  RUN_ALL_EXEC_LAUNCHED=0
  RUN_ALL_EXEC_STATE=UNSUPPORTED
  if tlr_match "$1" && [ "$TLR_STATUS" = supported ]; then supported=1; fi
  if [ "$supported" = 1 ] && ! _tlr_get "$TLR_ID" launch.requires && ! _tlr_get "$TLR_ID" launch.wrapper; then
    _tlr_get "$TLR_ID" launch.unit && unit="$_TLR_V"
    while [ "$i" -lt "${#_TLR_A_ID[@]}" ]; do
      [ "${_TLR_A_ID[$i]}" = "$TLR_ID" ] && argv="$argv|${_TLR_A_KIND[$i]}:${_TLR_A_VAL[$i]}"
      i=$((i + 1))
    done
  fi
  if [ "$unit" = file ] && [ "$argv" = "|command:bash|command:{path}" ]; then
    RUN_ALL_EXEC_LAUNCHED=1
    bash "$lpath" >"$2" 2>"$3" </dev/null || rc=$?
    case "$rc" in
      0) RUN_ALL_EXEC_STATE=PASS ;;
      77) RUN_ALL_EXEC_STATE=SKIP ;;
      *) RUN_ALL_EXEC_STATE=FAIL ;;
    esac
    return "$rc"
  fi
  if [ "$supported" = 1 ]; then
    RUN_ALL_EXEC_STATE=FAIL
    printf 'not run: %s (language: %s; launcher library not found)\n' "$1" "$TLR_ID" >"$2"
    return 2
  fi
  printf 'UNSUPPORTED: %s (language: %s; launcher library not found)\n' "$1" "${TLR_ID:-unknown}" >"$2"
  return 78
}
