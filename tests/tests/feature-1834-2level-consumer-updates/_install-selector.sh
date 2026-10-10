# Sourced by tests/tests/feature-1834-2level-consumer-updates.sh (needs SCRIPT_CHECKOUT_ROOT, SELECT_TESTS).
# install_selector <repo> — the real selector plus the test-language registry it loads (#2500).
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
install_selector() {
  mkdir -p "$1/bin/lib"
  cp "$SELECT_TESTS" "$1/bin/select-tests.sh"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/select-tests-stem.sh" "$1/bin/lib/select-tests-stem.sh"
  install_test_language_registry "$1" "$SCRIPT_CHECKOUT_ROOT"
}
