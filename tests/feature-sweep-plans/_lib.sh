# tests/feature-sweep-plans/_lib.sh
# Tests: bin/sweep-plans.sh
# Tags: sweep, plans, workflow-plans, maintenance, bin, scope:common
#
# Shared setup + helpers for the feature-sweep-plans split test groups.
# Sourced by core.sh and validation.sh — not runnable standalone.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-plans.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Backdate file mtime to look "stale" (60 days ago). Portable across GNU/BSD.
backdate() {
    local f="$1"
    touch -d "60 days ago" "$f" 2>/dev/null || touch -t 202401010000 "$f" 2>/dev/null || true
}

# Extract a field from --ci-mode JSON output (may contain non-JSON noise lines).
ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            const lines = b.split(/\r?\n/);
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try {
                    const d = JSON.parse(trimmed);
                    if (key in d) { console.log(d[key]); return; }
                } catch (e) { /* skip non-JSON */ }
            }
        });
    " -- "$2" 2>/dev/null
}
