#!/bin/bash
# tests/fix-933-enforce-worktree-plans-dir.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows.js
# Tags: worktree, enforce, hook, plans-dir, fix-933, scope:issue-specific
# Tests for isAllowedWorkflowPlansDirWrite() — #933
#
# L3 gap (what this test does NOT catch):
# - Real session env where WORKFLOW_PLANS_DIR is set via dotfiles vs .env.local vs system env
# - Windows symlink vs junction vs real directory path normalization at OS level
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"
ALLOWS_JS="${_A}/hooks/enforce-worktree/main-worktree-allows.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t mctest)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# Main repo with NO linked worktrees (post-worktree-end state).
MAIN_CLEAN="$TMPBASE/main-clean"
mkdir -p "$MAIN_CLEAN"
git -C "$MAIN_CLEAN" init -q -b main
git -C "$MAIN_CLEAN" config user.email "test@example.com"
git -C "$MAIN_CLEAN" config user.name "Test"
git -C "$MAIN_CLEAN" config core.hooksPath /dev/null
git -C "$MAIN_CLEAN" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then MAIN_CLEAN_N="$(cygpath -m "$MAIN_CLEAN")"; else MAIN_CLEAN_N="$MAIN_CLEAN"; fi

# FAKE_PLANS_DIR inside MAIN_CLEAN (not adjacent) so the isInSessionScope
# fast-allow path does not pre-empt the predicate under test.
FAKE_PLANS_DIR="$MAIN_CLEAN/fake-plans"
mkdir -p "$FAKE_PLANS_DIR"
if command -v cygpath >/dev/null 2>&1; then FAKE_PLANS_DIR_N="$(cygpath -m "$FAKE_PLANS_DIR")"; else FAKE_PLANS_DIR_N="$FAKE_PLANS_DIR"; fi

# Predicate-level check: isAllowedWorkflowPlansDirWrite(cmd, repoRoot) with WORKFLOW_PLANS_DIR env.
# WORKFLOW_PLANS_DIR_VAL is read first inside node and assigned BEFORE require()
# (so workflow-plans-dir.js cache reflects the test value).
check_ca() {
  local plans_dir="$1" cmd="$2" repo="$3"
  WORKFLOW_PLANS_DIR_VAL="$plans_dir" CMD_VAL="$cmd" REPO_VAL="$repo" ALLOWS_JS_VAL="$ALLOWS_JS" \
  run_with_timeout node -e "
    if (process.env.WORKFLOW_PLANS_DIR_VAL && process.env.WORKFLOW_PLANS_DIR_VAL.length) {
      process.env.WORKFLOW_PLANS_DIR = process.env.WORKFLOW_PLANS_DIR_VAL;
    } else {
      delete process.env.WORKFLOW_PLANS_DIR;
    }
    const mod = require(process.env.ALLOWS_JS_VAL);
    const fn = mod.isAllowedWorkflowPlansDirWrite;
    if (typeof fn !== 'function') { console.log('reject'); process.exit(0); }
    console.log(fn(process.env.CMD_VAL, process.env.REPO_VAL) ? 'allow' : 'reject');
  " 2>/dev/null
}
assert_allow_ca() { local got; got="$(check_ca "$1" "$2" "$3")"; [ "$got" = "allow"  ] && pass "$4" || fail "$4 (got=$got)"; }
assert_block_ca() { local got; got="$(check_ca "$1" "$2" "$3")"; [ "$got" = "reject" ] && pass "$4" || fail "$4 (got=$got)"; }

# End-to-end hook check. cwd, decision (ignored slot), cmd.
# The hook reads process.cwd() directly to decide main vs linked.
check_hook() {
  local cwd="$1" cmd="$3" plans_dir="${4:-}"
  local cmd_json
  cmd_json="$(CMDVAL="$cmd" node -e 'console.log(JSON.stringify(process.env.CMDVAL))' 2>/dev/null)"
  if [ -n "$plans_dir" ]; then
    ( cd "$cwd" && printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' \
        "$cmd_json" "$cwd" \
        | ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$_A" WORKFLOW_PLANS_DIR="$plans_dir" \
          run_with_timeout node "$GUARD_JS" 2>/dev/null )
  else
    ( cd "$cwd" && printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' \
        "$cmd_json" "$cwd" \
        | ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$_A" run_with_timeout node "$GUARD_JS" 2>/dev/null )
  fi
}
assert_hook_allow() {
  local out; out="$(check_hook "$1" "" "$2" "${4:-}")"
  if echo "$out" | grep -q '"decision":"block"'; then fail "$3 (got=block, expected allow; out=$out)"
  else pass "$3"; fi
}
assert_hook_block() {
  local out; out="$(check_hook "$1" "" "$2" "${4:-}")"
  if echo "$out" | grep -q '"decision":"block"'; then pass "$3"
  else fail "$3 (got=allow, expected block; out=$out)"; fi
}

# === P-series: predicate allow — WORKFLOW_PLANS_DIR set, target inside plans dir ===
assert_allow_ca "$FAKE_PLANS_DIR_N" "cat file > \"$FAKE_PLANS_DIR_N/out.md\"" "$MAIN_CLEAN_N" "P1: cat redirect to plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "cat file >> \"$FAKE_PLANS_DIR_N/out.md\"" "$MAIN_CLEAN_N" "P2: append redirect to plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "echo x > \"$FAKE_PLANS_DIR_N/sub/dir/out.md\"" "$MAIN_CLEAN_N" "P3: nested path under plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "tee \"$FAKE_PLANS_DIR_N/out.md\"" "$MAIN_CLEAN_N" "P4: tee write to plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "cat <<EOF > \"$FAKE_PLANS_DIR_N/out.md\"
content
EOF" "$MAIN_CLEAN_N" "P5: heredoc to plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "bash -c 'echo x > \"$FAKE_PLANS_DIR_N/out.md\"'" "$MAIN_CLEAN_N" "P6: bash -c with redirect to plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "mkdir \"$FAKE_PLANS_DIR_N/d\" && echo x > \"$FAKE_PLANS_DIR_N/d/f\"" "$MAIN_CLEAN_N" "P7: chained writes, all inside plans dir → allow"
assert_allow_ca "$FAKE_PLANS_DIR_N" "node -e \"fs.writeFileSync('$FAKE_PLANS_DIR_N/f', 'x')\"" "$MAIN_CLEAN_N" "P8: node inline write to plans dir → allow"

# === B-series: predicate block — target NOT inside plans dir ===
assert_block_ca "$FAKE_PLANS_DIR_N" "echo x > \"/tmp/outside.md\"" "$MAIN_CLEAN_N" "B1: write outside plans dir → block"
assert_block_ca "$FAKE_PLANS_DIR_N" "echo x > \"${MAIN_CLEAN_N}-plans/out.md\"" "$MAIN_CLEAN_N" "B2: sibling with prefix collision → block"
assert_block_ca "$FAKE_PLANS_DIR_N" "echo x > \"$FAKE_PLANS_DIR_N/ok.md\" && echo y > \"/tmp/bad.txt\"" "$MAIN_CLEAN_N" "B3: chained — one target outside plans dir → block"

# === PD-series: WORKFLOW_PLANS_DIR unset → default ~/.workflow-plans/ ===
DEFAULT_PLANS="$HOME/.workflow-plans"
if command -v cygpath >/dev/null 2>&1; then DEFAULT_PLANS_N="$(cygpath -m "$DEFAULT_PLANS")"; else DEFAULT_PLANS_N="$DEFAULT_PLANS"; fi
assert_allow_ca "" "echo x > \"$DEFAULT_PLANS_N/out.md\"" "$MAIN_CLEAN_N" "PD1: unset env, target under default plans dir → allow"
assert_block_ca "" "echo x > \"/tmp/elsewhere.md\"" "$MAIN_CLEAN_N" "PD2: unset env, target elsewhere → block"
assert_allow_ca "" "echo x > \"$DEFAULT_PLANS_N/sub/nested.md\"" "$MAIN_CLEAN_N" "PD3: unset env, nested under default plans dir → allow"

# === N-series: Windows path normalization (conditional on platform) ===
if [ "$(uname -s 2>/dev/null)" = "Linux" ] || [ "$(uname -s 2>/dev/null | cut -c1-5)" = "MINGW" ] || [ "$(uname -s 2>/dev/null | cut -c1-6)" = "CYGWIN" ] || [ "$(uname -s 2>/dev/null | cut -c1-5)" = "MSYS_" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|CYGWIN*|MSYS*)
      # Backslash form should normalize to forward-slash and match.
      BS_PATH="$(echo "$FAKE_PLANS_DIR_N/win.md" | tr '/' '\\')"
      assert_allow_ca "$FAKE_PLANS_DIR_N" "echo x > \"$BS_PATH\"" "$MAIN_CLEAN_N" "N1: backslash target matches forward-slash plans dir → allow"
      # Case-insensitive drive letter (only valid when path has C:/c: prefix).
      if echo "$FAKE_PLANS_DIR_N" | grep -qE '^[A-Za-z]:'; then
        LOWER_DRIVE="$(echo "$FAKE_PLANS_DIR_N" | sed -E 's|^([A-Z]):|\L\1:|')"
        assert_allow_ca "$FAKE_PLANS_DIR_N" "echo x > \"$LOWER_DRIVE/case.md\"" "$MAIN_CLEAN_N" "N2: lower-case drive letter matches → allow"
      fi
      ;;
    *)
      echo "INFO: N-series skipped on $(uname -s) (non-Windows platform)"
      ;;
  esac
else
  echo "INFO: N-series skipped on $(uname -s 2>/dev/null) (non-Windows platform)"
fi

# === E-series: end-to-end via real hook from MAIN_CLEAN cwd ===
assert_hook_allow "$MAIN_CLEAN_N" "echo x > \"$FAKE_PLANS_DIR_N/out.md\"" "E1: hook end-to-end — write to plans dir from main → allow" "$FAKE_PLANS_DIR_N"
assert_hook_allow "$MAIN_CLEAN_N" "cat <<EOF > \"$FAKE_PLANS_DIR_N/out.md\"
content
EOF" "E2: hook end-to-end — heredoc to plans dir from main → allow" "$FAKE_PLANS_DIR_N"
assert_hook_allow "$MAIN_CLEAN_N" "bash -c 'echo x > \"$FAKE_PLANS_DIR_N/f\"'" "E3: hook end-to-end — bash -c to plans dir from main → allow" "$FAKE_PLANS_DIR_N"
# E4: target inside MAIN_CLEAN but outside FAKE_PLANS_DIR — must NOT hit the
# session-scope fast-allow (which requires every target to be outside the repo),
# so the dispatch reaches the main-worktree block and our predicate must reject.
assert_hook_block "$MAIN_CLEAN_N" "echo x > \"$MAIN_CLEAN_N/elsewhere.md\"" "E4: hook end-to-end — write inside repo but outside plans dir from main → block" "$FAKE_PLANS_DIR_N"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
