=== bin/collect-tests.sh
for f in hooks/*.js tests/hooks/*.Tests.ps1; do add "$f"; done
find "$TESTS_DIR/bin" -maxdepth 1 -name '*.Tests.ps1'
echo "found tests/*.Tests.ps1 files"
=== hooks/stub.js
module.exports = {};
