=== bin/run-checks.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/foo-helper.sh"
bash "$DIR/../tests/run-all.sh" --all
node "$DIR/test-language-registry" --format shell
python3 "$DIR/normalize-harness-position.py" --dry-run
echo "see tests/lib/harness.sh and hooks/lib/kind.js"
