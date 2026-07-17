#!/bin/bash
# Tests: hooks/lib/parse-closes-issues.js, bin/parse-issue-tokens
# Tags: scope:issue-specific
#
# Fix 1499 — parseIssueToken must require a leading '#' for the issue number.
# Bug: bare digits inside prose (e.g. version string "bash 3.2") are parsed as
# issue tokens, producing spurious #3 / #2 references. The guard should only
# accept #N, repo#N, owner/repo#N — NOT bare N.
#
# BUGFIX session: the "rejection" cases below are EXPECTED TO FAIL against the
# pre-fix source. That fail-before-fix state is intentional evidence.
#
# L3 gap (what this test does NOT catch):
# - Real workflow-init-driver subprocess using parse-issue-tokens with live detect-issues.js
# - Windows-specific shell escaping differences in argv processing
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSE_CLOSES_ISSUES_JS="$REPO_ROOT/hooks/lib/parse-closes-issues.js"
PARSE_ISSUE_TOKENS="$REPO_ROOT/bin/parse-issue-tokens"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

assert_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        pass "$label (want='$want')"
    else
        fail "$label: want='$want' got='$got'"
    fi
}

# ---------------------------------------------------------------------------
# tok_result: null → "null", {number:N} → N (repo field ignored)
# ---------------------------------------------------------------------------
tok_result() {
    node -e "
const m = require(process.argv[1]);
const r = m.parseIssueToken(process.argv[2]);
process.stdout.write(r === null ? 'null' : String(r.number));
" "$PARSE_CLOSES_ISSUES_JS" "$1" 2>/dev/null
}

# parse_token_missing_arg: simulates parseIssueToken() with no argument.
parse_token_missing_arg() {
    run_with_timeout 10 node -e '
const { parseIssueToken } = require(process.argv[1]);
const r = parseIssueToken();
process.stdout.write(r == null ? "null" : String(r.number));
' "$PARSE_CLOSES_ISSUES_JS" 2>/dev/null
}

# jq_len / jq_elem helpers for CLI output (avoid /dev/stdin — Windows Git Bash).
jq_len() {
    node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).length));' "$1" 2>/dev/null || echo "error"
}
jq_elem() {
    node -e '
const d=JSON.parse(process.argv[1]);
const e=d[parseInt(process.argv[2])];
if(!e){process.stdout.write("undefined");}
else{process.stdout.write(String(e.number));}
' "$1" "$2" 2>/dev/null || echo "error"
}

if [ ! -f "$PARSE_CLOSES_ISSUES_JS" ]; then
    echo "FATAL: parse-closes-issues.js not found at $PARSE_CLOSES_ISSUES_JS"
    exit 1
fi

# ---------------------------------------------------------------------------
# Table-driven: parseIssueToken direct calls.
# Columns: name | input | want
#   want = "null" | "<number>"  (repo field is ignored by tok_result)
# ---------------------------------------------------------------------------
echo "=== parseIssueToken: table-driven cases ==="
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name// /}"
    want="${want// /}"
    got=$(tok_result "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
# --- accept: valid # prefix ---
accept-hash-N              | #1486          | 1486
accept-repo-hash-N         | dotfiles#77    | 77
accept-owner-repo-hash-N   | nirecom/agents#100 | 100
accept-hash-zero           | #0             | 0
# --- reject: bare digits (bug core) ---
reject-bare-version-string | 3.2            | null
reject-bare-number-1486    | 1486           | null
reject-bare-number-42      | 42             | null
# --- reject: # present but followed by non-digit (C1/C3) ---
reject-hash-then-letter    | 7#x            | null
reject-hash-then-word      | 42#notanumber  | null
reject-hash-then-empty     | 99#            | null
reject-hash-then-x         | bash3.2#x      | null
# --- edge: dotted prefix before valid # ---
edge-dotted-repo-prefix    | 3.2#1486       | 1486
# --- edge: empty string ---
edge-empty-string          |                | null
TABLE

# Empty-argument test: separate because TABLE cannot express a missing argv.
echo "=== parseIssueToken: missing argument ==="
GOT_MISSING="$(parse_token_missing_arg)"
if [ "$GOT_MISSING" = "null" ]; then
    pass "missing arg (null-equivalent) → null"
else
    fail "missing arg → null: got='$GOT_MISSING'"
fi

# ---------------------------------------------------------------------------
# End-to-end: bin/parse-issue-tokens CLI.
# ---------------------------------------------------------------------------
echo "=== bin/parse-issue-tokens CLI (end-to-end) ==="
if [ ! -f "$PARSE_ISSUE_TOKENS" ]; then
    skip "CLI: bin/parse-issue-tokens not found"
else
    # Reproduction string: the crash-report title with a bare "3.2" version.
    # Only #1486 should survive; the bare 3 (from "3.2") must NOT appear.
    REPRO="bin/github-issues/clarify-commit-scope.sh: unconditional declare -A crashes on macOS stock bash 3.2 #1486"
    OUT_REPRO=$(run_with_timeout 10 node "$PARSE_ISSUE_TOKENS" "$REPRO" 2>/dev/null)
    LEN_R=$(jq_len "$OUT_REPRO")
    N0_R=$(jq_elem "$OUT_REPRO" 0 "number")
    if [ "$LEN_R" = "1" ] && [ "$N0_R" = "1486" ]; then
        pass "CLI: repro string → [#1486] only (no spurious #3)"
    else
        fail "CLI: repro string: len=$LEN_R n0=$N0_R (want len=1 n0=1486) out=$OUT_REPRO"
    fi

    # All bare digits → empty array.
    OUT_BARE=$(run_with_timeout 10 node "$PARSE_ISSUE_TOKENS" "3.2 foo 42 hello" 2>/dev/null)
    LEN_B=$(jq_len "$OUT_BARE")
    if [ "$LEN_B" = "0" ]; then
        pass "CLI: all bare digits → [] (empty)"
    else
        fail "CLI: all bare digits: len=$LEN_B (want 0) out=$OUT_BARE"
    fi

    # Multiple valid tokens.
    OUT_MULTI=$(run_with_timeout 10 node "$PARSE_ISSUE_TOKENS" "#42 dotfiles#77" 2>/dev/null)
    LEN_M=$(jq_len "$OUT_MULTI")
    N0_M=$(jq_elem "$OUT_MULTI" 0 "number")
    N1_M=$(jq_elem "$OUT_MULTI" 1 "number")
    if [ "$LEN_M" = "2" ] && [ "$N0_M" = "42" ] && [ "$N1_M" = "77" ]; then
        pass "CLI: '#42 dotfiles#77' → 2 tokens [42, 77]"
    else
        fail "CLI: multi tokens: len=$LEN_M n0=$N0_M n1=$N1_M (want 2/42/77) out=$OUT_MULTI"
    fi
fi

# --- Mutation probe (advisory) ---
# Run: bin/mutation-probe.sh hooks/lib/parse-closes-issues.js
# Expected: ISSUE_TOKEN_BODY_RE mutations → T10b-core tests FAIL (80%+ kill)
# Note: fail-before-fix already establishes that rejection cases fail against
# the unpatched code; the probe is a secondary structural verification.

# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "TOTAL: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "==================================================================="
# BUGFIX fail-before-fix: rejection cases are expected to FAIL pre-fix.
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
