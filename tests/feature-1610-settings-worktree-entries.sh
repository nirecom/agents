#!/bin/bash
# tests/feature-1610-settings-worktree-entries.sh
# Tests: hooks/stop-exit-worktree-warn.js, hooks/postuse-native-worktree-record.js, settings.json
# Tags: settings, hook, worktree, enter-worktree, exit-worktree, registration, TL2, pwsh-not-required, scope:issue-specific
# P0 verdict: A-, P+, observed 2026-07-24, Claude Code 2.1.136
#
# Issue #1610 — settings.json wiring for the worktree-transition advisory pair.
# Verdict A- means no permissions.allow entry grants the EnterWorktree/ExitWorktree
# TOOL (the upstream consent dialog cannot be suppressed that way), so E2/E3 assert
# permanent absence. Verdict P+ means both PreToolUse and PostToolUse fire for these
# tools, so Step 8b's recorder registration (E6/E7) and Step 8c's Stop registration
# (E4/E5) are required once the source files land.
#
# TL3 gap (what this test does NOT catch):
# - Whether the registered hooks actually fire on a real Claude Code host; this file
#   only asserts static registration shape from settings.json.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOP_HOOK="$AGENTS_DIR/hooks/stop-exit-worktree-warn.js"
RECORDER="$AGENTS_DIR/hooks/postuse-native-worktree-record.js"
SETTINGS="$AGENTS_DIR/settings.json"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if ! command -v node >/dev/null 2>&1; then
    skip "whole file (node not available)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi; }

# E1 — sanity: settings.json parses as valid JSON.
run_E1() {
    local got
    got="$(run_with_timeout 60 node -e '
require(process.argv[1]);
process.stdout.write("ok");
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E1: settings.json parses as valid JSON" "ok" "$got"
}

# E2 — no permissions.allow entry grants the EnterWorktree TOOL. Must not
# false-positive on the "Bash(echo ...WORKFLOW_ENFORCE_WORKTREE_ON...)" entry,
# which allows a Bash *echo command*, not the EnterWorktree tool.
run_E2() {
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const allow=((s.permissions&&s.permissions.allow)||[]);
const hits=allow.filter(e=>{
  const first=String(e).split("(")[0];
  return first==="EnterWorktree";
});
process.stdout.write(String(hits.length));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E2: no permissions.allow entry grants the EnterWorktree tool" "0" "$got"
}

# E3 — no permissions.allow entry grants the ExitWorktree TOOL.
run_E3() {
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const allow=((s.permissions&&s.permissions.allow)||[]);
const hits=allow.filter(e=>{
  const first=String(e).split("(")[0];
  return first==="ExitWorktree";
});
process.stdout.write(String(hits.length));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E3: no permissions.allow entry grants the ExitWorktree tool" "0" "$got"
}

# E4 — Stop hooks array contains exactly one stop-exit-worktree-warn.js entry.
run_E4() {
    require_source "$STOP_HOOK" "E4: Stop hooks array has exactly one stop-exit-worktree-warn.js entry" || return
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const hooks=((s.hooks&&s.hooks.Stop&&s.hooks.Stop[0]&&s.hooks.Stop[0].hooks)||[]);
process.stdout.write(String(hooks.filter(h=>String(h.command||"").includes("stop-exit-worktree-warn.js")).length));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E4: Stop hooks array has exactly one stop-exit-worktree-warn.js entry" "1" "$got"
}

# E5 — the new Stop entry appears AFTER stop-enforce-worktree-on-warn.js.
run_E5() {
    require_source "$STOP_HOOK" "E5: stop-exit-worktree-warn.js registered after stop-enforce-worktree-on-warn.js" || return
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const hooks=((s.hooks&&s.hooks.Stop&&s.hooks.Stop[0]&&s.hooks.Stop[0].hooks)||[]);
const idxOn=hooks.findIndex(h=>String(h.command||"").includes("stop-enforce-worktree-on-warn.js"));
const idxExit=hooks.findIndex(h=>String(h.command||"").includes("stop-exit-worktree-warn.js"));
process.stdout.write((idxOn>=0 && idxExit>idxOn)?"ok":("idxOn="+idxOn+" idxExit="+idxExit));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E5: stop-exit-worktree-warn.js registered after stop-enforce-worktree-on-warn.js" "ok" "$got"
}

# E6 — PostToolUse contains exactly one group with matcher EnterWorktree|ExitWorktree
# that invokes postuse-native-worktree-record.js.
run_E6() {
    require_source "$RECORDER" "E6: exactly one PostToolUse group invokes postuse-native-worktree-record.js" || return
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const groups=((s.hooks&&s.hooks.PostToolUse)||[]).filter(g=>
  (g.hooks||[]).some(h=>String(h.command||"").includes("postuse-native-worktree-record.js")));
process.stdout.write(String(groups.length));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E6: exactly one PostToolUse group invokes postuse-native-worktree-record.js" "1" "$got"
}

# E7 — that recorder group's matcher is exactly "EnterWorktree|ExitWorktree",
# not attached to a broader/unrelated matcher.
run_E7() {
    require_source "$RECORDER" "E7: recorder group matcher is exactly EnterWorktree|ExitWorktree" || return
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const groups=((s.hooks&&s.hooks.PostToolUse)||[]).filter(g=>
  (g.hooks||[]).some(h=>String(h.command||"").includes("postuse-native-worktree-record.js")));
process.stdout.write(groups.map(g=>g.matcher||"").join(","));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "E7: recorder group matcher is exactly EnterWorktree|ExitWorktree" "EnterWorktree|ExitWorktree" "$got"
}

run_E1; run_E2; run_E3; run_E4; run_E5; run_E6; run_E7

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
