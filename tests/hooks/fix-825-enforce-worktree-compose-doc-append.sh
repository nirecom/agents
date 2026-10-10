#!/bin/bash
# tests/hooks/fix-825-enforce-worktree-compose-doc-append.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows.js
# Tags: worktree, enforce, hook, compose-doc-append, fix-825, scope:issue-specific
# Tests for isAllowedComposeDocAppend() — #825
set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"; else _A="$SCRIPT_CHECKOUT_ROOT"; fi
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

# The predicate accepts the script only under the checkout the guard itself runs from ($_A);
# since #2561 no environment variable names that root. The commands below therefore name
# "$_A/bin/compose-doc-append-entry" (compared as a path, never executed).
# FOREIGN_CHECKOUT: a look-alike checkout (script + both trust markers) that is NOT the guard's
# own — the W7/W8 cases name the script under it and must stay blocked.
FOREIGN_CHECKOUT="$TMPBASE/foreign-agents"
mkdir -p "$FOREIGN_CHECKOUT/bin" "$FOREIGN_CHECKOUT/hooks"
touch "$FOREIGN_CHECKOUT/bin/compose-doc-append-entry" "$FOREIGN_CHECKOUT/hooks/enforce-worktree.js"
if command -v cygpath >/dev/null 2>&1; then FOREIGN_CHECKOUT_N="$(cygpath -m "$FOREIGN_CHECKOUT")"; else FOREIGN_CHECKOUT_N="$FOREIGN_CHECKOUT"; fi

# Main repo with NO linked worktrees (post-worktree-end state)
MAIN_CLEAN="$TMPBASE/main-clean"
mkdir -p "$MAIN_CLEAN"
git -C "$MAIN_CLEAN" init -q -b main
git -C "$MAIN_CLEAN" config user.email "test@example.com"
git -C "$MAIN_CLEAN" config user.name "Test"
git -C "$MAIN_CLEAN" config core.hooksPath /dev/null
git -C "$MAIN_CLEAN" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then MAIN_CLEAN_N="$(cygpath -m "$MAIN_CLEAN")"; else MAIN_CLEAN_N="$MAIN_CLEAN"; fi

# Main repo WITH one linked worktree
MAIN_DIRTY="$TMPBASE/main-dirty"
mkdir -p "$MAIN_DIRTY"
git -C "$MAIN_DIRTY" init -q -b main
git -C "$MAIN_DIRTY" config user.email "test@example.com"
git -C "$MAIN_DIRTY" config user.name "Test"
git -C "$MAIN_DIRTY" config core.hooksPath /dev/null
git -C "$MAIN_DIRTY" commit --allow-empty --no-verify -q -m init
git -C "$MAIN_DIRTY" worktree add -q -b feature-x "$TMPBASE/dirty-wt" 2>/dev/null
if command -v cygpath >/dev/null 2>&1; then MAIN_DIRTY_N="$(cygpath -m "$MAIN_DIRTY")"; else MAIN_DIRTY_N="$MAIN_DIRTY"; fi
if command -v cygpath >/dev/null 2>&1; then DIRTY_WT_N="$(cygpath -m "$TMPBASE/dirty-wt")"; else DIRTY_WT_N="$TMPBASE/dirty-wt"; fi

# Predicate-level check: isAllowedComposeDocAppend(cmd, repoRoot) with AGENTS_MAIN_ROOT env.
# C3 fix from codex review: ALLOWS_JS_VAL must be BEFORE `node`, not after `node -e`.
check_ca() {
  local script_checkout_root="$1" cmd="$2" repo="$3"
  AGENTS_MAIN_ROOT_VAL="$script_checkout_root" CMD_VAL="$cmd" REPO_VAL="$repo" ALLOWS_JS_VAL="$ALLOWS_JS" \
  run_with_timeout node -e "
    process.env.AGENTS_MAIN_ROOT = process.env.AGENTS_MAIN_ROOT_VAL || '';
    const {isAllowedComposeDocAppend} = require(process.env.ALLOWS_JS_VAL);
    console.log(isAllowedComposeDocAppend(process.env.CMD_VAL, process.env.REPO_VAL) ? 'allow' : 'reject');
  " 2>/dev/null
}
assert_allow_ca() { local got; got="$(check_ca "$1" "$2" "$3")"; [ "$got" = "allow"  ] && pass "$4" || fail "$4 (got=$got)"; }
assert_block_ca() { local got; got="$(check_ca "$1" "$2" "$3")"; [ "$got" = "reject" ] && pass "$4" || fail "$4 (got=$got)"; }

# End-to-end hook check. cwd, decision (ignored arg slot), cmd.
# Must `cd` into cwd before invoking node — the hook reads process.cwd() directly
# (not the JSON cwd field) to decide main vs linked worktree.
check_hook() {
  local cwd="$1" cmd="$3"
  local cmd_json
  cmd_json="$(CMDVAL="$cmd" node -e 'console.log(JSON.stringify(process.env.CMDVAL))' 2>/dev/null)"
  ( cd "$cwd" && printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' \
      "$cmd_json" "$cwd" \
      | ENFORCE_WORKTREE=on AGENTS_MAIN_ROOT="$_A" run_with_timeout node "$GUARD_JS" 2>/dev/null )
}
assert_hook_allow() {
  local out; out="$(check_hook "$1" "" "$2")"
  if echo "$out" | grep -q '"decision":"block"'; then fail "$3 (got=block, expected allow; out=$out)"
  else pass "$3"; fi
}
assert_hook_block() {
  local out; out="$(check_hook "$1" "" "$2")"
  if echo "$out" | grep -q '"decision":"block"'; then pass "$3"
  else fail "$3 (got=allow, expected block; out=$out)"; fi
}

# Canonical command shape:
#   bash "<the guard's own checkout>/bin/compose-doc-append-entry" --notes ... --branch ... --pr ... --merge-commit ... --background ... --closes-issues-count ...

CANON="bash \"$_A/bin/compose-doc-append-entry\" --notes \"WORKTREE_NOTES.md\" --branch \"feature/x\" --pr 123 --merge-commit abc1234 --background \"bg\" --closes-issues-count 1"
BOOT="bash \"$_A/bin/compose-doc-append-entry\" --notes \"WORKTREE_NOTES.md\" --branch \"feature/x\" --bootstrap --merge-commit abc1234 --background \"bg\" --closes-issues-count 1"
BARE="bash \"$_A/bin/compose-doc-append-entry\""

# === P-series: canonical allow shapes ===
assert_allow_ca "$_A" "$CANON" "$MAIN_CLEAN_N" "P1: canonical normal-mode invocation → allow"
assert_allow_ca "$_A" "$BOOT"  "$MAIN_CLEAN_N" "P2: canonical bootstrap-mode invocation → allow"
assert_allow_ca "$_A" "$BARE"  "$MAIN_CLEAN_N" "P3: bare invocation (no args) → allow"
assert_allow_ca "$_A" "  bash \"$_A/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "P4: leading whitespace before bash → allow"
# P5: path with .. that normalizes to canonical.
P5_CMD="bash \"$_A/bin/../bin/compose-doc-append-entry\" --pr 1"
assert_allow_ca "$_A" "$P5_CMD" "$MAIN_CLEAN_N" "P5: path with .. normalizing to canonical → allow"
# P6/P7: the environment never decides — the guard's own script stays allowed whatever AGENTS_MAIN_ROOT holds.
assert_allow_ca "" "$CANON" "$MAIN_CLEAN_N" "P6: own-checkout script with AGENTS_MAIN_ROOT empty → allow (#2561)"
assert_allow_ca "$FOREIGN_CHECKOUT_N" "$CANON" "$MAIN_CLEAN_N" "P7: own-checkout script with AGENTS_MAIN_ROOT naming a foreign checkout → allow (#2561)"

# === C-series: redirect / substitution chars in args ===
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 > /tmp/out" "$MAIN_CLEAN_N" "C1a: stdout redirect > → block"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 >> /tmp/out" "$MAIN_CLEAN_N" "C1b: append redirect >> → block"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 < /tmp/in" "$MAIN_CLEAN_N" "C1c: input redirect < → block"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --background \"\$(touch /tmp/x)\"" "$MAIN_CLEAN_N" "C2a: \$() inside double-quoted arg → block"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --background \"\`touch /tmp/x\`\"" "$MAIN_CLEAN_N" "C2b: backtick inside double-quoted arg → block"

# === S-series: shell chaining / pipes (the root incident) ===
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 | tee /tmp/out" "$MAIN_CLEAN_N" "S1: pipe to tee → block (root incident)"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 && rm -rf /tmp/x" "$MAIN_CLEAN_N" "S2: && chaining → block"
assert_block_ca "$_A" "bash \"$_A/bin/compose-doc-append-entry\" --pr 1 ; echo done" "$MAIN_CLEAN_N" "S3: ; chaining → block"

# === W-series: wrong shapes ===
assert_block_ca "$_A" "bash \"$_A/bin/doc-append\" --pr 1" "$MAIN_CLEAN_N" "W1: wrong script name (doc-append) → block"
assert_block_ca "$_A" "bash \"$_A/scripts/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W2: correct script name in wrong directory → block"
assert_block_ca "$_A" "bash '$_A/bin/compose-doc-append-entry' --pr 1" "$MAIN_CLEAN_N" "W3: single-quoted script path → block"
assert_block_ca "$_A" "pwsh \"$_A/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W4: wrong interpreter pwsh → block"
assert_block_ca "$_A" "node \"$_A/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W5: wrong interpreter node → block"
assert_block_ca "$_A" "sudo bash \"$_A/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W6: sudo prefix → block"
assert_block_ca "" "bash \"$FOREIGN_CHECKOUT_N/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W7: script under a foreign checkout with AGENTS_MAIN_ROOT empty → block (#2561)"
assert_block_ca "$FOREIGN_CHECKOUT_N" "bash \"$FOREIGN_CHECKOUT_N/bin/compose-doc-append-entry\" --pr 1" "$MAIN_CLEAN_N" "W8: script under a foreign checkout that AGENTS_MAIN_ROOT names → block (#2561)"

# === E-series: end-to-end hook dispatch ===
# For E-series we use the real agents repo path ($_A) as AGENTS_MAIN_ROOT so that
# the hook can require modules and resolve real paths. We invoke `bash "$_A/bin/compose-doc-append-entry" ...`.
HOOK_CANON="bash \"$_A/bin/compose-doc-append-entry\" --notes \"WORKTREE_NOTES.md\" --branch \"feature/x\" --pr 123 --merge-commit abc1234 --background \"bg\" --closes-issues-count 1"
# Tee target must be inside the cwd's session scope (= cwd repo root). Session-scope
# fast-allow intervenes when ALL write targets resolve outside the session roots set;
# placing tee output inside the cwd repo keeps it inside scope so the dispatch path
# is exercised. The tee path must be UNQUOTED — extractTeeTargets returns the quoted
# form verbatim and findRepoRoot then returns null on a quoted-path string,
# triggering the very fast-allow we want to avoid.
HOOK_TEE="bash \"$_A/bin/compose-doc-append-entry\" --pr 1 | tee $MAIN_CLEAN_N/captured.log"

# E1: canonical from main worktree (MAIN_CLEAN) → allow (proves dispatch wiring)
assert_hook_allow "$MAIN_CLEAN_N" "$HOOK_CANON" "E1: end-to-end canonical from main → allow"
# E2: tee variant from main worktree → block
assert_hook_block "$MAIN_CLEAN_N" "$HOOK_TEE"   "E2: end-to-end tee variant from main → block"
# E3: canonical from a linked worktree → allow (worktree path always allows)
assert_hook_allow "$DIRTY_WT_N"   "$HOOK_CANON" "E3: end-to-end canonical from linked worktree → allow"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
