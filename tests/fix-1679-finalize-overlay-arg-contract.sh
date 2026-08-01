#!/usr/bin/env bash
# tests/fix-1679-finalize-overlay-arg-contract.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, security, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1679 widened the argument/path contract for finalize-worker invocations
# that reach PreToolUse from a main worktree: a `$AGENTS_CONFIG_DIR` literal
# prefix that arrives unexpanded, and the benign trailing segments `|| exit 0`
# and `2>&1`. It pinned that contract on matchFinalizeWorkerOverlay.
#
# #1673 deleted finalize-worker-overlay.js together with the Bash-tool `eval`
# path for the three finalize scripts, and desanctioned run-initial.sh. The
# suite split in two along that line:
#
#   LIVE — the widenings themselves did NOT go away. They live in
#          worker-script.js's `eval "$(bash "<path>")"` identity branch, which
#          still admits the literal-prefix normalization and both trailing
#          segments for the scripts that are still SANCTIONED. The LIVE1679-*
#          rows exercise them through skills/issue-close-finalize/scripts/
#          pre-flight.sh, the surviving member of that family. They are the
#          non-vacuous half: each must ALLOW, so a hook that simply blocks
#          everything from a main worktree cannot satisfy this file.
#   RETIRED — the AC1679-* rows asserted ALLOW for run-initial.sh evals carrying
#          positional arguments. No such command is permitted from a main
#          worktree any more (run-initial.sh is not SANCTIONED, and the eval
#          identity branch admits no argument tail at all), so they are
#          polarity-flipped to BLOCK and kept as retired-capability pins. Their
#          names and command shapes are unchanged on purpose: they are the
#          provenance of what #1679 once opened, and the record that reopening
#          any of those shapes is a regression, not a feature.
#   BK1679-* — the security boundary. BLOCK before #1679, BLOCK after it, and
#          BLOCK after #1673. Untouched.
#
# Drive surface: the real enforce-worktree.js hook process over a Bash payload,
# from a throwaway git main worktree. #1679 drove the matcher function directly;
# with the matcher gone, the hook boundary is the closest surviving seam and is
# strictly more faithful — it also covers the worker-script.js delegation that
# #1679 listed as its own TL3 gap.
#
# TL3 gap (what this TL2 test does NOT catch):
# - whether the PreToolUse registration in settings.json routes a real Bash tool
#   call into this hook at all
# - a real symlinked checkout (~/.claude/* -> agents repo) where the module path
#   and the realpath candidate genuinely differ
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASS=0; FAIL=0; SKIP=0

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not found";  exit 77; }
if command -v cygpath >/dev/null 2>&1; then WT="$(cygpath -m "$AGENTS_DIR")"; else WT="$AGENTS_DIR"; fi

GUARD_JS="${WT}/hooks/enforce-worktree.js"
[ -f "$GUARD_JS" ] || { echo "FAIL: precondition missing — $GUARD_JS"; echo "Total: PASS=0 FAIL=1"; exit 1; }

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t fix1679arg)"
trap 'rm -rf "$TMP_ROOT" 2>/dev/null' EXIT

# ---------------------------------------------------------------------------
# Fixture: a real git main worktree (the hook shells out to `git`) plus a
# marker-valid AGENTS_CONFIG_DIR. resolveAgentsConfigDir refuses a directory
# without the markers, so bin/ and hooks/enforce-worktree.js must exist.
# ---------------------------------------------------------------------------
REPO_RAW="$TMP_ROOT/repo"
ACD_RAW="$TMP_ROOT/acd"
mkdir -p "$REPO_RAW"
mkdir -p "$ACD_RAW/bin" "$ACD_RAW/hooks" "$ACD_RAW/skills/issue-close-finalize/scripts"
touch "$ACD_RAW/hooks/enforce-worktree.js" \
      "$ACD_RAW/bin/check-unstaged-tracked.sh" \
      "$ACD_RAW/skills/issue-close-finalize/scripts/pre-flight.sh" \
      "$ACD_RAW/skills/issue-close-finalize/scripts/run-initial.sh"

# MSYS_NO_PATHCONV=1 (set above so the payload strings survive verbatim) also
# stops `git -C` from receiving a converted path, and native git cannot resolve
# an MSYS `/tmp/...` argument. Convert BEFORE the first git call — a silently
# failed `git init` leaves the hook unable to resolve a repo root, which turns
# every ALLOW row into a "cannot determine repo root" block.
if command -v cygpath >/dev/null 2>&1; then
  REPO="$(cygpath -m "$REPO_RAW")"; ACD="$(cygpath -m "$ACD_RAW")"
else
  REPO="$REPO_RAW"; ACD="$ACD_RAW"
fi
SCRIPTS="$ACD/skills/issue-close-finalize/scripts"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config core.hooksPath /dev/null
echo "init" > "$REPO_RAW/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q --no-verify -m "initial"
git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "FAIL: fixture main worktree is not a git repo"; echo "Total: PASS=0 FAIL=1"; exit 1; }

json_quote() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

GUARD_OUT=""
GUARD_RC=0
# guard_verdict <cmd> [acdEnvMode] → sets GUARD_RC: 0 allow, 1 block, 2 crash.
#   acdEnvMode: "same" (default — AGENTS_CONFIG_DIR = ACD), "unset",
#               or an explicit replacement value.
guard_verdict() {
  local cmd="$1" mode="${2:-same}"
  local payload; payload="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(json_quote "$cmd")")"
  # `env` takes its -u options BEFORE any NAME=VALUE operand, so the unset flags
  # are assembled first — appending them after the assignments makes env treat
  # "-u" as a command name.
  local -a envargs
  envargs=(env -u CLAUDE_ENV_FILE)
  [ "$mode" = "unset" ] && envargs+=(-u AGENTS_CONFIG_DIR)
  envargs+=("ENFORCE_WORKTREE=on" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$REPO")
  case "$mode" in
    same)  envargs+=("AGENTS_CONFIG_DIR=$ACD") ;;
    unset) : ;;
    *)     envargs+=("AGENTS_CONFIG_DIR=$mode") ;;
  esac
  GUARD_RC=0
  GUARD_OUT="$(cd "$REPO" && printf '%s' "$payload" | run_with_timeout 30 \
      "${envargs[@]}" node "$GUARD_JS" 2>&1)" || GUARD_RC=2
  [ "$GUARD_RC" -eq 2 ] && return 0
  echo "$GUARD_OUT" | grep -q '"decision":"block"' && GUARD_RC=1
  return 0
}

assert_allow() {
  local name="$1" cmd="$2" mode="${3:-same}"
  guard_verdict "$cmd" "$mode"
  case "$GUARD_RC" in
    0) pass "$name" ;;
    1) fail "$name — want=ALLOW got=BLOCK cmd=$(printf '%q' "$cmd") out: $GUARD_OUT" ;;
    *) fail "$name — want=ALLOW got=CRASH cmd=$(printf '%q' "$cmd") out: $GUARD_OUT" ;;
  esac
}

assert_block() {
  local name="$1" cmd="$2" mode="${3:-same}"
  guard_verdict "$cmd" "$mode"
  case "$GUARD_RC" in
    1) pass "$name" ;;
    0) fail "$name — want=BLOCK got=ALLOW cmd=$(printf '%q' "$cmd")" ;;
    *) fail "$name — want=BLOCK got=CRASH cmd=$(printf '%q' "$cmd") out: $GUARD_OUT" ;;
  esac
}

# ---------------------------------------------------------------------------
# Command builders. Single-quoted printf formats keep " and $( verbatim.
# ---------------------------------------------------------------------------
# The surviving identity shape: eval "$(bash "<path>")" with an optional
# trailing 2>&1 and/or || exit 0, and no argument tail.
build_eval() { printf 'eval "$(bash "%s")"%s' "$1" "${2:-}"; }

#   $1 AGENTS_CONFIG_DIR value  $2 FINALIZE_SCRIPTS_DIR value
#   $3 MAIN_WORKTREE_PATH value $4 script path literal
#   $5 pre-quoted argument tail $6 trailing text after the eval wrapper
build_initial() {
  printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s" %s)"%s' \
    "$1" "$2" "$3" "$4" "$5" "${6:-}"
}

# Standard (fully-resolved) env span + script path; only args/tail vary.
std_initial() { build_initial "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS/run-initial.sh" "$1" "${2:-}"; }

# ===========================================================================
# LIVE — the #1679 widenings on the surviving sanctioned script. These are the
# rows that keep this file non-vacuous: they must ALLOW.
# ===========================================================================
echo "=== LIVE: #1679 widenings that survive on pre-flight.sh ==="

assert_allow "LIVE1679-1: resolved literal path, no tail → ALLOW" \
  "$(build_eval "$SCRIPTS/pre-flight.sh")"

assert_allow "LIVE1679-2 (G1): \$AGENTS_CONFIG_DIR literal prefix reaching PreToolUse unexpanded → ALLOW" \
  "$(build_eval '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh')"

assert_allow "LIVE1679-3: trailing || exit 0 → ALLOW" \
  "$(build_eval "$SCRIPTS/pre-flight.sh" ' || exit 0')"

assert_allow "LIVE1679-4: trailing 2>&1 fd-dup → ALLOW" \
  "$(build_eval "$SCRIPTS/pre-flight.sh" ' 2>&1')"

assert_allow "LIVE1679-5: both trailing segments together (2>&1 || exit 0) → ALLOW" \
  "$(build_eval "$SCRIPTS/pre-flight.sh" ' 2>&1 || exit 0')"

# Paired negatives for the LIVE rows — the normalization must not degrade into
# "any variable prefix" or "any trailing text", which is how a widening breaks.
assert_block "LIVE1679-6: \$EVIL prefix instead of \$AGENTS_CONFIG_DIR → BLOCK" \
  "$(build_eval '$EVIL/skills/issue-close-finalize/scripts/pre-flight.sh')"

# The #1673 delta itself, isolated: byte-identical to LIVE1679-2 except for the
# script FILENAME. run-initial.sh left SANCTIONED, so the literal-prefix
# normalization must not carry it — the prefix is a path rewrite, never a
# licence for the directory it names.
# (No "env var UNSET" row here: resolveAgentsConfigDir is marker-validated and
# discovers the config dir from the module location, so unsetting the variable
# does not make the prefix unresolvable — it would only measure the machine the
# suite runs on.)
assert_block "LIVE1679-7: same literal prefix, desanctioned run-initial.sh → BLOCK (#1673)" \
  "$(build_eval '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh')"

assert_block "LIVE1679-8: trailing redirect to a file (> out.txt) → BLOCK" \
  "$(build_eval "$SCRIPTS/pre-flight.sh" ' > out.txt')"

assert_block "LIVE1679-9: an argument tail on the eval identity form → BLOCK" \
  "$(printf 'eval "$(bash "%s" "1234")"' "$SCRIPTS/pre-flight.sh")"

# ===========================================================================
# RETIRED (#1673) — the AC1679-* ALLOW contract for run-initial.sh. The script
# is no longer SANCTIONED and the eval path that carried these shapes is gone,
# so every row is now a BLOCK pin over the exact command #1679 once admitted.
# ===========================================================================
echo "=== AC (polarity-flipped): run-initial.sh eval shapes, retired by #1673 ==="

assert_block "AC1679-1: 3 args with empty arg3 placeholder — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234" ""')"

assert_block "AC1679-2 (G2): 2 args, arg3 omitted (current-repo form) — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234"')"

assert_block "AC1679-3 (G3): 3 args, arg3 = owner/repo — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234" "nirecom/agents"')"

assert_block "AC1679-4 (G3): 3 args, arg3 = bare repo name (no slash) — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234" "agents"')"

assert_block "AC1679-5: 2-arg form with a trailing || exit 0 — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234"' ' || exit 0')"

assert_block "AC1679-6 (G1): \$AGENTS_CONFIG_DIR literal prefix in the script path — eval path retired (#1673)" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "AC1679-7 (G1): \${AGENTS_CONFIG_DIR} braced literal prefix in the script path — eval path retired (#1673)" \
  "$(build_initial "$ACD" "$SCRIPTS" "$REPO" '${AGENTS_CONFIG_DIR}/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "AC1679-8 (G1): literal prefix in the script path AND in FINALIZE_SCRIPTS_DIR — eval path retired (#1673)" \
  "$(build_initial "$ACD" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts' "$REPO" '$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/run-initial.sh' '"1234" "1234" ""')"

assert_block "AC1679-9: 3-arg form with a trailing 2>&1 fd-dup — eval path retired (#1673)" \
  "$(std_initial '"1234" "1234" ""' ' 2>&1')"

# ===========================================================================
# BLOCK boundary (BK) — blocked before #1679, after it, and after #1673.
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
