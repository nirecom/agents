# shellcheck shell=bash
# tests/lib/test-language-registry-fixture.sh — installs the real test-language registry into a fixture root.
# Tests: tests/lib/test-language-registry-fixture.sh
# Tags: test-infrastructure, test-language-registry, shared-lib, scope:common
# One owner for the file set a fixture needs so the registry loads from it (#2500):
# the table, its JS reader, the CLI, the bash loader, every per-language part, and
# every part file the table names elsewhere (e.g. a caseMarkerReader "file").
# The loader resolves the CLI and table from its own location, so the set must keep
# the repo layout. A test that needs a modified table installs this set, then
# overwrites the one file it changes.

TLR_FIXTURE_SRC_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# install_test_language_registry <root> [<agents-src>] — copies the set into <root>,
# creating parent dirs. <agents-src> defaults to the checkout holding this helper.
# Returns 1 with a message on stderr when any source file is missing.
install_test_language_registry() {
  local root="${1:?install_test_language_registry: <root> required}"
  local src="${2:-$TLR_FIXTURE_SRC_DEFAULT}" rel part
  local -a files=(bin/test-language-registry bin/lib/test-language-registry.sh
    hooks/lib/test-language-registry.js hooks/lib/test-language-registry.json)
  for part in "$src"/bin/lib/test-language-parts/*.sh; do
    [ -f "$part" ] || continue
    files+=("bin/lib/test-language-parts/${part##*/}")
  done
  if [ "${#files[@]}" -eq 4 ]; then
    printf 'install_test_language_registry: no parts under %s/bin/lib/test-language-parts\n' "$src" >&2
    return 1
  fi
  # Parts registered outside the parts dir: read them from the table, not a copied list.
  while IFS= read -r rel; do
    case " ${files[*]} " in *" $rel "*) ;; *) files+=("$rel") ;; esac
  done < <(grep -o '"file"[[:space:]]*:[[:space:]]*"[^"]*"' "$src/hooks/lib/test-language-registry.json" 2>/dev/null \
    | sed 's/.*"\([^"]*\)"$/\1/')
  for rel in "${files[@]}"; do
    if [ ! -f "$src/$rel" ]; then
      printf 'install_test_language_registry: missing source %s/%s\n' "$src" "$rel" >&2
      return 1
    fi
  done
  for rel in "${files[@]}"; do
    mkdir -p "$root/$(dirname "$rel")" || return 1
    cp "$src/$rel" "$root/$rel" || return 1
  done
}
