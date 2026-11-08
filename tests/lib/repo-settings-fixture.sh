# shellcheck shell=bash
# tests/lib/repo-settings-fixture.sh — installs the real repo settings reader into a fixture root.
# Tests: tests/lib/repo-settings-fixture.sh
# Tags: test-infrastructure, repo-settings, shared-lib, scope:common
# One owner for the file set bin/lib/repo-settings.sh needs to load from a fixture (#2473): the
# bash loader, the CLI it runs from its own location, the JS reader with its modules, and the
# .agents.json it reads. With any of them absent the loader silently takes RSF_LEGACY_CATEGORIES.

RSF_FIXTURE_SRC_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# install_repo_settings <root> [<agents-src>] [<agents-json>] — copies the set into <root>, creating
# parent dirs, and writes <root>/.agents.json: <agents-json> when given, else <agents-src>'s file.
# Returns 1 with a message on stderr when any source file is missing.
install_repo_settings() {
  local root="${1:?install_repo_settings: <root> required}"
  local src="${2:-$RSF_FIXTURE_SRC_DEFAULT}" rel part
  local -a files=(bin/repo-settings bin/lib/repo-settings.sh hooks/lib/repo-settings.js)
  for part in "$src"/hooks/lib/repo-settings/*.js; do
    [ -f "$part" ] && files+=("${part#"$src"/}")
  done
  if [ "${#files[@]}" -eq 3 ]; then
    printf 'install_repo_settings: no modules under %s/hooks/lib/repo-settings\n' "$src" >&2
    return 1
  fi
  [ $# -ge 3 ] || files+=(.agents.json)
  for rel in "${files[@]}"; do
    if [ ! -f "$src/$rel" ]; then
      printf 'install_repo_settings: missing source %s/%s\n' "$src" "$rel" >&2
      return 1
    fi
  done
  for rel in "${files[@]}"; do
    mkdir -p "$root/$(dirname "$rel")" || return 1
    cp "$src/$rel" "$root/$rel" || return 1
  done
  if [ $# -ge 3 ]; then
    printf '%s\n' "$3" >"$root/.agents.json" || return 1
  fi
}
