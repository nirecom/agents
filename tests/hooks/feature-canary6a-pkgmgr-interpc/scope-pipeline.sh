#!/usr/bin/env bash
# tests/feature-canary6a-pkgmgr-interpc/scope-pipeline.sh
# Tests: hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree.js, hooks/lib/bash-write-targets/pkg-mgr.js, hooks/lib/bash-write-targets.js
# Tags: scope:issue-specific, pkg-mgr, interpreter-c, canary-6a, enforce-worktree, scope-pipeline, hook-registration, pwsh-not-required
#
# Full scope pipeline (#1411): after the pkg-mgr / interpreter-c WRITE_PATTERNS
# entries are retired, isPkgMgrWriteIR / isInterpreterCWriteIR must reach the
# enforce-worktree fast-allow gate so an in-session pkg-mgr / interpreter-c write
# is BLOCKED from the main worktree, and an out-of-session write is ALLOWED. The
# collect→scope wiring (collectBashWriteTargets, isEverySegmentExcluded) must treat
# a pkg-mgr / interpreter-c write segment as a write.
#
# RED-pending: when pkg-mgr.js / isInterpreterCWriteIR are absent, the collector /
# segment-exclusion rows below FAIL cleanly (predicate ERROR:* ≠ expected). The
# module-present gate SKIPs the pkg-mgr-only rows when pkg-mgr.js is entirely absent
# so the dispatcher stays green pre-impl.
#
# L3 gap (what this test does NOT catch):
# - Real enforce-worktree hook invocation with an actual command going through the full PreToolUse pipeline (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - Session-scoped worktree path comparison in a real Claude session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Fixtures: a main-worktree git repo (in-session) + a non-git CWD ────────────
TMPBASE="$(run_with_timeout 30 node -e "var o=require('os'),p=require('path'),f=require('fs');var d=p.join(o.tmpdir(),'canary6a-'+process.pid);f.mkdirSync(d,{recursive:true});process.stdout.write(d);" 2>/dev/null)"
[ -z "$TMPBASE" ] && { skip "could not create temp base"; report_totals; exit 0; }
trap 'rm -rf "$TMPBASE" 2>/dev/null || true' EXIT

MAIN_REPO="${TMPBASE}/repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q --no-verify -m "initial"

if command -v cygpath >/dev/null 2>&1; then MAIN_REPO_NODE="$(cygpath -m "$MAIN_REPO")"; else MAIN_REPO_NODE="$MAIN_REPO"; fi

_make_payload() {
  run_with_timeout 30 node -e "var o={tool_name:'Bash',tool_input:{command:process.argv[1]},session_id:'canary6a'};process.stdout.write(JSON.stringify(o));" -- "$1" 2>/dev/null
}
# hook_decision <cmd> <cwd> → "block"|"allow"
hook_decision() {
  local cmd="$1" cwd="$2"
  local p out
  p="$(_make_payload "$cmd")"
  out="$( cd "$cwd" && ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$MAIN_REPO_NODE" CLAUDE_SESSION_ID=canary6a MSYS_NO_PATHCONV=1 run_with_timeout 20 node "$GUARD_JS" <<< "$p" 2>/dev/null )"
  echo "$out" | grep -q '"decision":"block"' && { echo block; return; }
  echo allow
}

# ── isEverySegmentExcluded / collectBashWriteTargets direct probes ─────────────
# A pkg-mgr / interpreter-c write segment must count as a WRITE in isEverySegmentExcluded
# (it has no local file target, so a sequence containing it can never be "all excluded"
# → false → block). Pre-impl the predicate is missing so the write segment is treated
# as a transparent read → returns true (WRONG) → assertion FAILs (RED-pending).
ese() {
  run_with_timeout 30 node -e "
    const {isEverySegmentExcluded}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    try { process.stdout.write(String(isEverySegmentExcluded(parse(process.argv[1]), process.argv[2], ['.worktree-backup/**']))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" "$2" 2>/dev/null
}

echo "=== HK: hook block/allow decision (in-session main worktree) ==="
# In-session pkg-mgr / interpreter-c write from the main worktree → BLOCK.
if pkg_mgr_module_present; then
  assert_eq "HK-npm-install in-session → block" "block" "$(hook_decision 'npm install foo' "$MAIN_REPO")"
  assert_eq "HK-cargo-check in-session → block (fail-closed)" "block" "$(hook_decision 'cargo check' "$MAIN_REPO")"
  assert_eq "HK-npm-frobnicate in-session → block (fail-closed unknown)" "block" "$(hook_decision 'npm frobnicate' "$MAIN_REPO")"
  # Read pkg-mgr command from the main worktree → ALLOW (not a write).
  assert_eq "HK-npm-list in-session → allow (read)" "allow" "$(hook_decision 'npm list' "$MAIN_REPO")"
else
  skip "HK pkg-mgr rows — pkg-mgr.js not yet implemented (RED-pending)"
fi
assert_eq "HK-bash-c-rm in-session → block" "block" "$(hook_decision 'bash -c "rm foo"' "$MAIN_REPO")"
assert_eq "HK-bash-c-ls in-session → allow (read body)" "allow" "$(hook_decision 'bash -c "ls"' "$MAIN_REPO")"

echo "=== PRED: predicate values backing the pipeline ==="
if pkg_mgr_module_present; then
  assert_eq "PRED-npm-install isPkgMgrWriteIR=true" "true" "$(pkg_mgr_write_ir 'npm install foo')"
  assert_eq "PRED-cargo-check isPkgMgrWriteIR=true (fail-closed)" "true" "$(pkg_mgr_write_ir 'cargo check')"
  assert_eq "PRED-npm-frobnicate isPkgMgrWriteIR=true (fail-closed)" "true" "$(pkg_mgr_write_ir 'npm frobnicate')"
else
  skip "PRED pkg-mgr rows — pkg-mgr.js not yet implemented (RED-pending)"
fi
assert_eq "PRED-bash-c-rm isInterpreterCWriteIR=true" "true" "$(interpreter_c_write_ir 'bash -c "rm foo"')"
assert_eq "PRED-bash-c-ls isInterpreterCWriteIR=false" "false" "$(interpreter_c_write_ir 'bash -c "ls"')"

echo "=== ESE: isEverySegmentExcluded — pkg-mgr / interpreter-c write segment counts as write ==="
# A sequenced command whose file segment is EXCLUDE-covered but whose pkg-mgr /
# interpreter-c segment is a write with NO local target must NOT be "all excluded".
if pkg_mgr_module_present; then
  assert_eq "ESE-cp-excluded && npm install → false (not all excluded)" \
    "false" "$(ese 'cp a .worktree-backup/x/f && npm install' "$MAIN_REPO_NODE")"
fi
assert_eq "ESE-cp-excluded && bash -c rm → false (not all excluded)" \
  "false" "$(ese 'cp a .worktree-backup/x/f && bash -c "rm foo"' "$MAIN_REPO_NODE")"

report_totals
exit "$FAIL"
