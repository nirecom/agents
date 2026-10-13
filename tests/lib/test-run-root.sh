#!/usr/bin/env bash
# tests/lib/test-run-root.sh — sourced. The run root (#2590): the one directory a test run may
# write in. TMPDIR / TMP / TEMP point into it, so mktemp and os.tmpdir() land there, and the
# command guard (tests/lib/command-guard.sh) allows git writes only below it.
#   test_run_root_ensure   reuse TEST_RUN_ROOT or create one, then pin the temp variables
# Exports: TEST_RUN_ROOT (mixed form), TEST_HOST_TMPDIR (the temp area the run started from,
# mixed form; caches live there, see tests/lib/test-cache-base.js), TMPDIR / TMP / TEMP.

_test_run_root_form() {
  local form="$1" p="$2"
  if command -v cygpath >/dev/null 2>&1; then cygpath "-$form" "$p"; else printf '%s\n' "$p"; fi
}

_test_run_root_user() {
  local u="${USER:-${USERNAME:-}}"
  [[ -n "$u" ]] || u="$(id -un 2>/dev/null)"
  [[ -n "$u" ]] || u=user
  printf '%s\n' "${u//[^A-Za-z0-9._-]/_}"
}

# _test_run_root_create — a fresh run-<pid>-<rand> under <host>/agents-test-runs-<user>,
# after removing run-* dirs left more than a day ago.
_test_run_root_create() {
  local parent dir
  parent="$TEST_HOST_TMPDIR/agents-test-runs-$(_test_run_root_user)"
  mkdir -p "$parent" || { echo "test_run_root_ensure: cannot create $parent" >&2; return 1; }
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mmin +1440 -exec rm -rf {} + 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do
    dir="$parent/run-$$-$RANDOM$RANDOM"
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  echo "test_run_root_ensure: cannot create a run root under $parent" >&2
  return 1
}

test_run_root_ensure() {
  local host root
  # Nothing moved since this lib last pinned: skip the path conversions (a process each on Windows).
  if [[ -n "${TEST_RUN_ROOT:-}" && -n "${TEST_HOST_TMPDIR:-}" && -d "${TMPDIR:-}" &&
    "${_TEST_RUN_ROOT_PIN:-}" == "$TEST_RUN_ROOT"$'\x1f'"$TMPDIR"$'\x1f'"${TMP:-}"$'\x1f'"${TEMP:-}" ]]; then
    return 0
  fi
  if [[ -z "${TEST_HOST_TMPDIR:-}" ]]; then
    host="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
    TEST_HOST_TMPDIR="$(_test_run_root_form m "$host")"
    export TEST_HOST_TMPDIR
  fi
  if [[ -n "${TEST_RUN_ROOT:-}" ]]; then
    root="$TEST_RUN_ROOT"
  else
    root="$(_test_run_root_create)" || return 1
  fi
  mkdir -p "$root/tmp" || { echo "test_run_root_ensure: cannot create $root/tmp" >&2; return 1; }
  TEST_RUN_ROOT="$(_test_run_root_form m "$root")"
  # MSYS keeps TMPDIR in POSIX form so PATH="$TMPDIR/x:$PATH" stays valid; Windows tools read TMP / TEMP.
  TMPDIR="$(_test_run_root_form u "$root/tmp")"
  TMP="$(_test_run_root_form w "$root/tmp")"
  TEMP="$TMP"
  # Unit separator (0x1f) between the fields: no path holds it, and env dumps stay one line each.
  _TEST_RUN_ROOT_PIN="$TEST_RUN_ROOT"$'\x1f'"$TMPDIR"$'\x1f'"$TMP"$'\x1f'"$TEMP"
  export TEST_RUN_ROOT TMPDIR TMP TEMP _TEST_RUN_ROOT_PIN
}
