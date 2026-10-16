#!/usr/bin/env bash
# tests/lib/command-guard.sh — sourced. The command guard (#2590): a bin dir first on PATH that
# stops gh / glab / codex (exit 97 + a hit) and lets git write only inside the run root
# (tests/lib/test-run-root.sh). Design: docs/architecture/claude-code/test-command-guard.md
#   command_guard_ensure          reuse COMMAND_GUARD_DIR or $TEST_RUN_ROOT/command-guard, else build it; prepend its bin
#   command_guard_hit_fields <f>  set _CG_HIT_STUB / _CG_HIT_ID / _CG_HIT_TARGET from one hit record (no subshell)
#   command_guard_hits <dir>      one "<stub><TAB><test id><TAB><target>" line per recorded hit
#   command_guard_hit_count <dir> number of recorded hits
#   command_guard_use_real        take every guard bin off PATH (TL3 / TL4 tests only)

_COMMAND_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_command_guard_form() {
  local form="$1" p="$2"
  if command -v cygpath >/dev/null 2>&1; then cygpath "-$form" "$p"; else printf '%s\n' "$p"; fi
}

# _command_guard_strip_into <path> — sets _CG_STRIPPED to the PATH value without any
# */command-guard/bin entry, in this shell (no subshell: a fork each on Windows).
_command_guard_strip_into() {
  local d rest="$1:"
  _CG_STRIPPED=""
  while [[ -n "$rest" ]]; do
    d="${rest%%:*}"
    rest="${rest#*:}"
    case "${d%/}" in */command-guard/bin) continue ;; esac
    _CG_STRIPPED="${_CG_STRIPPED:+$_CG_STRIPPED:}$d"
  done
}

# _command_guard_strip_path <path> — the same value, printed.
_command_guard_strip_path() {
  _command_guard_strip_into "$1"
  printf '%s\n' "$_CG_STRIPPED"
}

command_guard_ensure() {
  local dir realgit builder stripped
  _command_guard_strip_into "$PATH"
  stripped="$_CG_STRIPPED"
  # The guard this lib last pinned is still in place: reuse its bin path without converting it.
  if [[ -n "${COMMAND_GUARD_DIR:-}" && "${_COMMAND_GUARD_PIN:-}" == "$COMMAND_GUARD_DIR"$'\x1f'* && -f "$COMMAND_GUARD_DIR/guard.conf" ]]; then
    PATH="${_COMMAND_GUARD_PIN#"$COMMAND_GUARD_DIR"$'\x1f'}:$stripped"
    export PATH
    return 0
  fi
  if [[ -n "${COMMAND_GUARD_DIR:-}" ]]; then
    dir="$COMMAND_GUARD_DIR"
  else
    if [[ -z "${TEST_RUN_ROOT:-}" ]]; then
      echo "command_guard_ensure: TEST_RUN_ROOT is unset; source tests/lib/test-run-root.sh and run test_run_root_ensure first" >&2
      return 1
    fi
    dir="$TEST_RUN_ROOT/command-guard"
    if [[ ! -f "$dir/guard.conf" ]]; then
      if ! realgit="$(PATH="$stripped" command -v git)" || [[ -z "$realgit" ]]; then
        echo "command_guard_ensure: no git on PATH outside the guard" >&2
        return 1
      fi
      builder="$(_command_guard_form m "$_COMMAND_GUARD_LIB_DIR/command-guard-build.js")"
      if ! node "$builder" --instance "$(_command_guard_form m "$dir")" --allowed "$(_command_guard_form m "$TEST_RUN_ROOT")" \
        --realgit "$(_command_guard_form m "$realgit")"; then
        echo "command_guard_ensure: cannot build the command guard at $dir" >&2
        return 1
      fi
    fi
  fi
  if [[ ! -f "$dir/guard.conf" ]]; then
    echo "command_guard_ensure: $dir has no guard.conf" >&2
    return 1
  fi
  COMMAND_GUARD_DIR="$(_command_guard_form m "$dir")"
  # Unit separator (0x1f) between the fields: no path holds it, and env dumps stay one line each.
  _COMMAND_GUARD_PIN="$COMMAND_GUARD_DIR"$'\x1f'"$(_command_guard_form u "$COMMAND_GUARD_DIR/bin")"
  PATH="${_COMMAND_GUARD_PIN#"$COMMAND_GUARD_DIR"$'\x1f'}:$stripped"
  export COMMAND_GUARD_DIR _COMMAND_GUARD_PIN PATH
}

command_guard_use_real() {
  _command_guard_strip_into "$PATH"
  PATH="$_CG_STRIPPED"
  export PATH
  return 0
}

command_guard_hit_fields() {
  local line
  _CG_HIT_STUB="" _CG_HIT_ID="" _CG_HIT_TARGET=""
  [[ -f "${1:-}" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      stub=*) _CG_HIT_STUB="${line#stub=}" ;;
      test_id=*) _CG_HIT_ID="${line#test_id=}" ;;
      target=*) _CG_HIT_TARGET="${line#target=}" ;;
    esac
  done <"$1"
}

command_guard_hits() {
  local dir="${1:-}" f
  [[ -n "$dir" ]] || { echo "command_guard_hits: guard directory required" >&2; return 2; }
  for f in "$dir"/hits/*.hit; do
    [[ -f "$f" ]] || continue
    command_guard_hit_fields "$f"
    printf '%s\t%s\t%s\n' "$_CG_HIT_STUB" "$_CG_HIT_ID" "$_CG_HIT_TARGET"
  done
}

command_guard_hit_count() {
  local dir="${1:-}" n=0 f
  [[ -n "$dir" ]] || { echo "command_guard_hit_count: guard directory required" >&2; return 2; }
  for f in "$dir"/hits/*.hit; do
    [[ -f "$f" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
