=== tests/run-all.sh
if [ "$WANT_ALL" -eq 1 ] || [ $# -eq 0 ]; then
  # Six categories' direct test files only.
  for cat in hooks bin skills agents install tests; do
    for f in "$TESTS_DIR/$cat"/*.sh "$TESTS_DIR/$cat"/*.Tests.ps1 "$TESTS_DIR/$cat"/test_*.py; do add_work "$f"; done
  done
fi
