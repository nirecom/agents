=== bin/run-category-tests.sh
cd "$TESTS_DIR" || exit 1
for f in hooks/*.Tests.ps1; do pwsh "$f"; done
for f in skills/test_*.py; do uv run "$f"; done
for f in hooks/*.js; do lint "$f"; done
=== hooks/stub.js
module.exports = {};
=== skills/demo/scripts/run.sh
echo ok
