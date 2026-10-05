=== bin/review-sources.sh
TESTS_HINT="tests/run-all.sh"
for f in hooks/*.js skills/**/*.sh; do lint "$f"; done
find hooks/ -maxdepth 1 -name '*.js'
find skills -name "*.sh"
case "$f" in hooks/*.js|skills/*.sh) lint "$f" ;; esac
git diff --name-only | grep -E '^hooks/[^/]+\.js$'
echo "No .sh files changed"
=== hooks/stub.js
module.exports = {};
=== skills/demo/scripts/run.sh
echo ok
