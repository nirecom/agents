# shellcheck shell=bash
# bin/lib/repo-settings.sh — bash side of the repo settings file (<root>/.agents.json). Source only.
# Reads `node bin/repo-settings --root <root> --format shell` once per (CLI, root) into variables
# and arrays, as bin/lib/test-language-registry.sh does for its table.
# Works on bash 3.2: indexed arrays only, no declare (a sourcing function would make them local).
# Schema and state meanings: docs/architecture/claude-code/repo-settings-file.md.

_rsf_dir="${BASH_SOURCE[0]}"
case "$_rsf_dir" in */*) _rsf_dir="${_rsf_dir%/*}" ;; *) _rsf_dir=. ;; esac
_RSF_SELF_CLI="$(cd "$_rsf_dir/.." && pwd)/repo-settings"

if [ -z "${_RSF_INIT+x}" ]; then
  _RSF_INIT=1
  RSF_LOADED_KEY=""
  _RSF_CAT=(); _RSF_COVERS=(); _RSF_SUPPORT=(); _RSF_MIG_KEY=(); _RSF_MIG_VAL=(); _RSF_ERR=()
fi

_rsf_err() { printf '[repo-settings] %s\n' "$1" >&2; }

# rsf_load <root> — sets RSF_TESTS_STATE (ok|missing|malformed|unsupported), RSF_TESTS_DIR, RSF_CATEGORIZATION,
# RSF_TEST_HARNESS, RSF_CASE_MARKER, RSF_MIGRATE_STATE; a no-op when this CLI already read this root.
# rc 0 when the file was judged (any state), 2 when the CLI could not run.
rsf_load() {
  local root="${1:?rsf_load: root required}" key out rc cli kind a b
  key="$_RSF_SELF_CLI|$root"
  [ -n "$RSF_LOADED_KEY" ] && [ "$RSF_LOADED_KEY" = "$key" ] && return 0
  if ! command -v node >/dev/null 2>&1; then
    _rsf_err "node not on PATH; cannot read $root/.agents.json"
    return 2
  fi
  cli="$_RSF_SELF_CLI"
  command -v cygpath >/dev/null 2>&1 && cli="$(cygpath -m "$cli")" && root="$(cygpath -m "$root")"
  rc=0
  out="$(node "$cli" --root "$root" --format shell 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    _rsf_err "cannot read $root/.agents.json (rc=$rc)"
    return 2
  fi
  RSF_LOADED_KEY=""
  RSF_TESTS_STATE=""; RSF_TESTS_DIR=""; RSF_CATEGORIZATION=""; RSF_TEST_HARNESS=""; RSF_CASE_MARKER=""; RSF_MIGRATE_STATE=""
  _RSF_CAT=(); _RSF_COVERS=(); _RSF_SUPPORT=(); _RSF_MIG_KEY=(); _RSF_MIG_VAL=(); _RSF_ERR=()
  # shellcheck disable=SC2034 # RSF_* are read by the sourcing scripts
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      tests_state) RSF_TESTS_STATE="$a" ;;
      tests_dir) RSF_TESTS_DIR="$a" ;;
      categorization) RSF_CATEGORIZATION="$a" ;;
      testHarness) RSF_TEST_HARNESS="$a" ;;
      caseMarker) RSF_CASE_MARKER="$a" ;;
      category) _RSF_CAT+=("$a"); _RSF_COVERS+=("$b") ;;
      support) _RSF_SUPPORT+=("$a") ;;
      migrate_state) RSF_MIGRATE_STATE="$a" ;;
      migrate) _RSF_MIG_KEY+=("$a"); _RSF_MIG_VAL+=("$b") ;;
      error) _RSF_ERR+=("$a: $b") ;;
    esac
  done <<<"$out"
  if [ -z "$RSF_TESTS_STATE" ]; then
    _rsf_err "malformed shell dump from $cli"
    return 2
  fi
  # shellcheck disable=SC2034 # read by the sourcing scripts
  RSF_LOADED_KEY="$key"
  return 0
}

# rsf_categories — the category dirs, one per line (none for flat or a section that is not ok).
rsf_categories() {
  [ "${#_RSF_CAT[@]}" -eq 0 ] || printf '%s\n' "${_RSF_CAT[@]}"
}

# RSF_LEGACY_CATEGORIES — the named exception (#2473): the categories a root without a valid tests
# section (or a CLI that cannot run) is placed by, the ones every tool hard-coded before.
RSF_LEGACY_CATEGORIES=(hooks bin skills agents install tests)

# rsf_categories_into <root> — RSF_CATS: root's category dirs (none for flat), or
# RSF_LEGACY_CATEGORIES; RSF_TEST_DIRS: the entrypoint dirs relative to root (rsf_test_dirs), or
# tests/<legacy category>; RSF_CATS_LEGACY=1 marks the fallback. Never fails.
rsf_categories_into() {
  local c d
  RSF_CATS=()
  RSF_TEST_DIRS=()
  RSF_CATS_LEGACY=0
  if rsf_load "${1:?rsf_categories_into: root required}" 2>/dev/null && [ "$RSF_TESTS_STATE" = ok ]; then
    for c in ${_RSF_CAT[@]+"${_RSF_CAT[@]}"}; do RSF_CATS+=("$c"); done
    while IFS= read -r d; do [ -n "$d" ] && RSF_TEST_DIRS+=("$d"); done < <(rsf_test_dirs)
    return 0
  fi
  # shellcheck disable=SC2034 # read by the sourcing scripts
  RSF_CATS_LEGACY=1
  RSF_CATS=("${RSF_LEGACY_CATEGORIES[@]}")
  for c in "${RSF_LEGACY_CATEGORIES[@]}"; do RSF_TEST_DIRS+=("tests/$c"); done
  return 0
}

# rsf_support_dirs — the support dirs, one per line.
rsf_support_dirs() {
  [ "${#_RSF_SUPPORT[@]}" -eq 0 ] || printf '%s\n' "${_RSF_SUPPORT[@]}"
}

# rsf_test_dirs — the dirs holding test entrypoints, relative to the root: <dir> for flat,
# <dir>/<category> otherwise.
rsf_test_dirs() {
  local c
  [ "$RSF_TESTS_STATE" = ok ] || return 0
  if [ "$RSF_CATEGORIZATION" = flat ]; then printf '%s\n' "$RSF_TESTS_DIR"; return 0; fi
  for c in ${_RSF_CAT[@]+"${_RSF_CAT[@]}"}; do printf '%s/%s\n' "$RSF_TESTS_DIR" "$c"; done
}

# rsf_sweep_dirs_into <root> [<tests-dir-override>] — RSF_SWEEP_TESTS_DIR (<root>/<dir>) and
# RSF_SWEEP_DIRS (the entrypoint dirs, <root>-prefixed). A non-empty override skips the file: the
# legacy categories under it. rc 0 ok, 1 tests section not ok (RSF_TESTS_STATE names it), 2 CLI failed.
rsf_sweep_dirs_into() {
  local root="${1:?rsf_sweep_dirs_into: root required}" d
  RSF_SWEEP_DIRS=()
  RSF_SWEEP_TESTS_DIR="${2:-}"
  if [ -n "$RSF_SWEEP_TESTS_DIR" ]; then
    for d in "${RSF_LEGACY_CATEGORIES[@]}"; do RSF_SWEEP_DIRS+=("$RSF_SWEEP_TESTS_DIR/$d"); done
    return 0
  fi
  rsf_load "$root" || return 2
  [ "$RSF_TESTS_STATE" = ok ] || return 1
  # shellcheck disable=SC2034 # read by the sourcing scripts
  RSF_SWEEP_TESTS_DIR="$root/$RSF_TESTS_DIR"
  while IFS= read -r d; do [ -n "$d" ] && RSF_SWEEP_DIRS+=("$root/$d"); done < <(rsf_test_dirs)
  return 0
}

# rsf_is_category <name> — rc 0 when <name> is a category dir.
rsf_is_category() {
  local c
  for c in ${_RSF_CAT[@]+"${_RSF_CAT[@]}"}; do [ "$c" = "$1" ] && return 0; done
  return 1
}

# rsf_migrate_done <key> — rc 0 when migrate.<key> is done.
rsf_migrate_done() {
  local i=0
  while [ "$i" -lt "${#_RSF_MIG_KEY[@]}" ]; do
    [ "${_RSF_MIG_KEY[$i]}" = "$1" ] && [ "${_RSF_MIG_VAL[$i]}" = "done" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# rsf_errors — the validation errors of the last load, one per line.
rsf_errors() {
  [ "${#_RSF_ERR[@]}" -eq 0 ] || printf '%s\n' "${_RSF_ERR[@]}"
}
