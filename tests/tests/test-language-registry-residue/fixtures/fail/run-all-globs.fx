=== tests/run-all.sh
if [ "$WANT_ALL" -eq 1 ] || [ $# -eq 0 ]; then
  # The categories of the target's .agents.json, direct test files only.
  for cat in "${RS_CATEGORIES[@]}"; do
    for f in "$TESTS_DIR/$cat"/*.sh "$TESTS_DIR/$cat"/*.Tests.ps1 "$TESTS_DIR/$cat"/test_*.py; do add_work "$f"; done
  done
fi
