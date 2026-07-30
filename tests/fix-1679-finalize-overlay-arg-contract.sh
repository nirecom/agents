#!/usr/bin/env bash
# tests/fix-1679-finalize-overlay-arg-contract.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js, agents/issue-close-finalize-worker.md
# Tags: enforce-worktree, allowlist, security, TL1, pwsh-not-required, scope:issue-specific
#
# Issue #1679 — matchFinalizeWorkerOverlay's argument/path contract is narrower
# than the invocation shapes the finalize worker documents and actually emits:
#   G2  run-initial.sh's `argCountMin: 3` rejects the 2-argument form, which is
#       the documented shape for a current-repo issue (arg3 owner/repo omitted).
#   G3  ID_VALUE_RE (`[A-Za-z0-9._-]*`) has no `/`, so a legitimate `owner/repo`
#       third argument is rejected.
#   G1  The `[$`~]` reject on the script literal and on env VALUES refuses the
#       `$AGENTS_CONFIG_DIR` / `${AGENTS_CONFIG_DIR}` literal prefix that reaches
#       PreToolUse unexpanded — the same prefix worker-script.js's legacy eval
#       path already normalizes.
#   Plus benign trailing segments (`|| exit 0`, `2>&1`) the outer wrapper regex
#   does not admit.
#
# AC1679-* rows assert the POST-FIX ALLOW contract; the rows named in the table
# below are RED before the fix. BK1679-* rows are the security boundary and are
# GREEN before AND after the fix — every widening above must keep them blocked.
#
# Drive surface: matchFinalizeWorkerOverlay(cmd, acd, repoRoot) called directly.
# Non-null return = ALLOW (the overlay claims the command), null = BLOCK.
#
# TL3 gap (what this test does NOT catch):
# - Whether matchFinalizeWorkerOverlay is actually called via the real enforce-worktree.js hook process
# - Whether worker-script.js correctly delegates to matchFinalizeWorkerOverlay
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASS=0; FAIL=0; SKIP=0

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
if command -v cygpath >/dev/null 2>&1; then WT="$(cygpath -m "$AGENTS_DIR")"; else WT="$AGENTS_DIR"; fi

OVERLAY_JS="${WT}/hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ---------------------------------------------------------------------------
# Fixture: an acd + repoRoot pair. matchFinalizeWorkerOverlay is pure path math
# (path.resolve / normalizeForCompare) — no file needs to exist on disk — but
# real directories are created anyway so the fixture stays faithful if the fix
# ever adds an existence check.
# ---------------------------------------------------------------------------
TMP_ROOT="$(run_with_timeout 30 node -e "
  const os=require('os'),path=require('path'),fs=require('fs');
  const d=path.join(os.tmpdir(),'fix1679-overlay-'+process.pid).replace(/\\\\/g,'/');
  fs.mkdirSync(path.join(d,'acd','skills','issue-close-finalize','scripts'),{recursive:true});
  fs.mkdirSync(path.join(d,'repo'),{recursive:true});
  console.log(d);
" 2>/dev/null)"
[ -z "$TMP_ROOT" ] && { echo "FAIL: fixture root could not be created"; echo "Total: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

ACD="$TMP_ROOT/acd"
REPO="$TMP_ROOT/repo"
SCRIPTS="$ACD/skills/issue-close-finalize/scripts"

# overlay_match <cmd> [acdEnvMode] → "match" | "null" | "ERROR:*"
# acdEnvMode: "same" (default — process.env.AGENTS_CONFIG_DIR = ACD),
#             "unset", or an explicit replacement value.
overlay_match() {
  local cmd="$1" mode="${2:-same}"
  local -a envargs
  case "$mode" in
    same)  envargs=(env "AGENTS_CONFIG_DIR=$ACD") ;;
    unset) envargs=(env -u AGENTS_CONFIG_DIR) ;;
    *)     envargs=(env "AGENTS_CONFIG_DIR=$mode") ;;
  esac
  run_with_timeout 30 "${envargs[@]}" node -e "
    const m=require('${OVERLAY_JS}');
    if (typeof m.matchFinalizeWorkerOverlay !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try {
      const r = m.matchFinalizeWorkerOverlay(process.argv[1], process.argv[2], process.argv[3]);
      process.stdout.write(r === null || r === undefined ? 'null' : 'match');
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$cmd" "$ACD" "$REPO" 2>/dev/null
}

assert_allow() {
  local name="$1" cmd="$2" mode="${3:-same}"
  local got; got="$(overlay_match "$cmd" "$mode")"
  if [ "$got" = "match" ]; then pass "$name"
  else fail "$name — want=match got=$(printf '%q' "$got") cmd=$(printf '%q' "$cmd")"; fi
}

assert_block() {
  local name="$1" cmd="$2" mode="${3:-same}"
  local got; got="$(overlay_match "$cmd" "$mode")"
  if [ "$got" = "null" ]; then pass "$name"
  else fail "$name — want=null got=$(printf '%q' "$got") cmd=$(printf '%q' "$cmd")"; fi
}

# ---------------------------------------------------------------------------
# Command builders. Single-quoted printf formats keep " and $( verbatim.
#   $1 AGENTS_CONFIG_DIR value  $2 FINALIZE_SCRIPTS_DIR value
#   $3 MAIN_WORKTREE_PATH value $4 script path literal
#   $5 pre-quoted argument tail $6 trailing text after the eval wrapper
# ---------------------------------------------------------------------------
build_initial() {
  printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s" %s)"%s' \
    "$1" "$2" "$3" "$4" "$5" "${6:-}"
}

# Standard (fully-resolved) env span + script path; only args/tail vary.
std_initial() { build_initial "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS/run-initial.sh" "$1" "${2:-}"; }

# ===========================================================================
# ALLOW contract (AC) — the documented invocation shapes.
# ===========================================================================
echo "=== AC: run-initial.sh ALLOW contract ==="

assert_allow "AC1679-1: 3 args with empty arg3 placeholder → ALLOW (existing contract)" \
  "$(std_initial '"1234" "1234" ""')"

assert_allow "AC1679-2 (G2): 2 args, arg3 omitted (current-repo form) → ALLOW (RED before fix)" \
  "$(std_initial '"1234" "1234"')"

assert_allow "AC1679-3 (G3): 3 args, arg3 = owner/repo → ALLOW (RED before fix)" \
  "$(std_initial '"1234" "1234" "nirecom/agents"')"

assert_allow "AC1679-4 (G3): 3 args, arg3 = bare repo name (no slash) → ALLOW" \
  "$(std_initial '"1234" "1234" "agents"')"

assert_allow "AC1679-5: 2-arg form with a trailing || exit 0 → ALLOW (RED before fix)" \
  "$(std_initial '"1234" "1234"' ' || exit 0')"

assert_allow "AC1679-6 (G1): \$AGENTS_CONFIG_DIR literal prefix in the script path → ALLOW (RED before fix)" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_allow "AC1679-7 (G1): \${AGENTS_CONFIG_DIR} braced literal prefix in the script path → ALLOW (RED before fix)" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '${AGENTS_CONFIG_DIR}/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_allow "AC1679-8 (G1): literal prefix in the script path AND in FINALIZE_SCRIPTS_DIR → ALLOW (RED before fix)" \
  "$(build_initial "$ACD" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts' "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_allow "AC1679-9: 3-arg form with a trailing 2>&1 fd-dup → ALLOW (RED before fix)" \
  "$(std_initial '"1234" "1234" ""' ' 2>&1')"

# ===========================================================================
# BLOCK boundary (BK) — must stay blocked before AND after every widening above.
# ===========================================================================
echo "=== BK: run-initial.sh BLOCK boundary ==="

assert_block "BK1679-1: 1 argument only (below the documented minimum) → BLOCK" \
  "$(std_initial '"1234"')"

assert_block "BK1679-2: 4 arguments (above the documented maximum) → BLOCK" \
  "$(std_initial '"1234" "1234" "nirecom/agents" "extra"')"

assert_block "BK1679-3: arg3 with two slashes (a/b/c is not owner/repo) → BLOCK" \
  "$(std_initial '"1234" "1234" "a/b/c"')"

assert_block "BK1679-4: arg3 path traversal (../evil) → BLOCK" \
  "$(std_initial '"1234" "1234" "../evil"')"

assert_block "BK1679-5: arg3 carrying a command separator (owner/repo;id) → BLOCK" \
  "$(std_initial '"1234" "1234" "owner/repo;id"')"

assert_block "BK1679-6: arg3 carrying a command substitution → BLOCK" \
  "$(std_initial '"1234" "1234" "$(id)"')"

assert_block "BK1679-7a: script path prefixed with a DIFFERENT variable (\$EVIL) → BLOCK" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '$EVIL/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "BK1679-7b: \$AGENTS_CONFIG_DIR in the MIDDLE of the script path, not as prefix → BLOCK" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" 'C:/x/$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "BK1679-7c-unset: \$AGENTS_CONFIG_DIR literal prefix with the env var UNSET → BLOCK" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')" \
  "unset"

assert_block "BK1679-7c-mismatch: \$AGENTS_CONFIG_DIR literal prefix with env pointing elsewhere → BLOCK" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')" \
  "/different/path"

assert_block "BK1679-7d-dynamic: eval \"\$DYNAMIC\" (no structural match) → BLOCK" \
  'eval "$DYNAMIC"'

assert_block "BK1679-7d-varscript: eval \"\$SOMEVAR/x.sh\" (no structural match) → BLOCK" \
  'eval "$SOMEVAR/x.sh"'

assert_block "BK1679-7e: ~ home-expansion prefix in the script path → BLOCK" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '~/agents/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "BK1679-8: node used as the interpreter for run-initial.sh → BLOCK" \
  "$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" node "%s" "1234" "1234" "")"' \
      "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS/run-initial.sh")"

assert_block "BK1679-9: trailing redirect to a file (> out.txt) → BLOCK" \
  "$(std_initial '"1234" "1234" ""' ' > out.txt')"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
