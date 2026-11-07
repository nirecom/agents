# Sourced by tests/tests/feature-1834-2level-consumer-updates.sh (needs SCRIPT_CHECKOUT_ROOT, SELECT_TESTS).
# Tests: bin/select-tests.sh
# Tags: TL2, test-infrastructure, select-tests, repo-settings, scope:issue-specific
# install_selector <repo> — the real selector plus the test-language registry (#2500) and the repo
# settings reader with this checkout's .agents.json (#2473) it loads.
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
# shellcheck source=../../lib/repo-settings-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/repo-settings-fixture.sh"
install_selector() {
  mkdir -p "$1/bin/lib"
  cp "$SELECT_TESTS" "$1/bin/select-tests.sh"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/select-tests-stem.sh" "$1/bin/lib/select-tests-stem.sh"
  install_repo_settings "$1" "$SCRIPT_CHECKOUT_ROOT"
  install_test_language_registry "$1" "$SCRIPT_CHECKOUT_ROOT"
}
