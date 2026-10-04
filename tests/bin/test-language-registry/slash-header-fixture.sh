# shellcheck shell=bash
# Shared fixture for the header-comment-prefix cases (#2500): a minimal agents checkout
# whose registry table is fixtures/slash-header.json — bash ("#") plus the fixture-only
# slash-lang (*.slt, "//"). The loader has no env override, so the table is installed
# as the checkout's own default table; the real repo table is never touched.
# Sourced by the test files that exercise one header reader each.
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/test-language-registry-fixture.sh"

# slash_fx_checkout <dir> <agents-dir> [<repo-relative path>...] — copies bin/lib, the
# registry CLI/reader, harness.sh and the given extra scripts, then makes it a git repo.
slash_fx_checkout() {
  local d="$1" src="$2" f
  shift 2
  mkdir -p "$d/bin" "$d/hooks/lib" "$d/tests/lib"
  cp -R "$src/bin/lib" "$d/bin/lib"
  install_test_language_registry "$d" "$src" || return 1
  cp "$src/tests/bin/test-language-registry/fixtures/slash-header.json" "$d/hooks/lib/test-language-registry.json"
  cp "$src/tests/lib/harness.sh" "$d/tests/lib/harness.sh"
  for f in "$@"; do
    mkdir -p "$d/$(dirname "$f")"
    cp -R "$src/$f" "$d/$f"
  done
  git init -q "$d"
  git -C "$d" config core.hooksPath /dev/null
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
}

# slash_write <path> <line>... — writes the lines, creating the parent directory.
slash_write() {
  local p="$1"
  shift
  mkdir -p "$(dirname "$p")"
  printf '%s\n' "$@" >"$p"
}
