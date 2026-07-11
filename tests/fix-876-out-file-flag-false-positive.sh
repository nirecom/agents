#!/bin/bash
# tests/fix-876-out-file-flag-false-positive.sh
# Tests: hooks/lib/bash-write-patterns.js
# Tags: hook, classify, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real pwsh runtime behavior if Out-File regex match is position-unaware in a future change
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Regression evidence: the out-file-cli-* cases FAIL against the CURRENT
# bash-write-patterns.js (an Out-File CLI *flag* is misclassified as a write).
# That is the #876 defect to fix in write-code. This test is intentionally
# tolerant of those expected FAILs (exit 0) so it can be committed alongside
# the failing implementation as fail-before-fix evidence.
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
WP="${_A}/hooks/lib/bash-write-patterns.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if [ -x "${_A}/bin/run-with-timeout.sh" ]; then "${_A}/bin/run-with-timeout.sh" 30 "$@";
  elif command -v timeout >/dev/null 2>&1; then timeout 30 "$@";
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
classify() {
  run_with_timeout node -e "const {classify}=require('$WP');console.log(classify(process.argv[1]))" -- "$1" 2>/dev/null
}
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass "$name (=$got)"; else fail "$name (want=$want got=$got)"; fi
}

# Field delimiter is @@ (not a bare pipe) because test inputs contain shell pipes.
while IFS=$'\t' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    # Trim leading/trailing whitespace from the raw input only.
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    got=$(classify "$input")
    assert_eq "$name" "$want" "$got"
done < <(sed 's/@@/\t/g' <<'TABLE'
# #876 regression: --out-file CLI flag must NOT trigger Out-File write pattern
out-file-cli-flag@@pwsh script.ps1 --out-file result.txt@@read
out-file-cli-flag2@@node dist/bundle.js --out-file output.js@@read
out-file-cli-flag3@@tool --dry-run --out-file /tmp/report.txt@@read
# Real Out-File cmdlet (PowerShell command position) must still trigger write
out-file-cmdlet@@Out-File -FilePath result.txt@@write
out-file-pipeline@@Get-Process | Out-File process.txt@@write
TABLE
)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
