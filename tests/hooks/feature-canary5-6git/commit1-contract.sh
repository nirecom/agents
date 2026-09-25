#!/usr/bin/env bash
# tests/feature-canary5-6git/commit1-contract.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js, hooks/block-shell-config.js, hooks/block-history-direct.js, hooks/block-memory-direct.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, typed-target, contract-migration, scope:issue-specific, hook-registration, pwsh-not-required
#
# Commit 1 — typed {resolveVia,path} contract (behavior-neutral de-risk).
# RED-pending (fail-before-impl): the typed-shape cases (S1..S6) expect
#   collectWriteTargetsFromSegments to wrap each target as
#   {"resolveVia":"ancestor","path":"..."}; pre-impl it returns the bare string
#   "..." → these FAIL now, pass after the collector wraps (D1).
# PASS-now (preserved behavior): the string-API extractor pins (P*), the block-*
#   hook L2 cases, and the enforce-worktree behavior-neutral L2 cases all pass
#   against current source (Commit 1 changes nothing user-visible).
#
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js / block-*.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== S: collectWriteTargetsFromSegments typed shape (RED-pending-impl) ==="
# Post-impl each collected target is {resolveVia:"ancestor", path:"/tmp/..."}.
# Pre-impl it is the bare string → FAIL now (correct fail-before-impl evidence).
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(collect_first_target "$cmd")"
done <<'S_TABLE'
S1 redirect typed shape^printf x > /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S2 tee typed shape^cat x | tee /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S3 pwsh typed shape^Out-File -FilePath /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S4 cp typed shape^cp src /tmp/dest^{"resolveVia":"ancestor","path":"/tmp/dest"}
S5 mv typed shape^mv a /tmp/dest^{"resolveVia":"ancestor","path":"/tmp/dest"}
S6 rm typed shape^rm /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S_TABLE

echo "=== P: extractor string-API return pins (PASS now — proves wrap is at collector, D1) ==="
# The 5 extractors keep their bare string[] / string public API. If the impl
# wrongly wrapped inside the extractor, these would break — proving the wrap
# lives in the collector (D1), not the extractors.
assert_eq "P1 redirect string API bare array" '["/tmp/foo"]'  "$(call_extractor_str redirect extractRedirectTargets 'printf x > /tmp/foo')"
assert_eq "P2 tee string API bare array"       '["/tmp/foo"]'  "$(call_extractor_str tee extractTeeTargets 'echo x | tee /tmp/foo')"
assert_eq "P3 pwsh string API bare array"      '["/tmp/foo"]'  "$(call_extractor_str pwsh extractPwshWriteTargets 'Out-File -FilePath /tmp/foo')"
assert_eq "P4 cp-mv string API bare string"    '"/tmp/dest"'   "$(call_extractor_str cp-mv extractCpMvDestination 'cp src /tmp/dest')"
assert_eq "P5 rm string API bare array"        '["/tmp/foo"]'  "$(call_extractor_str rm extractRmTargets 'rm /tmp/foo')"

echo "=== IDEM: collectBashWriteTargets idempotency (no state mutation) ==="
# Calling collectBashWriteTargets twice on the SAME ir object must return
# identical results — no caching side effects, no in-place mutation of the ir.
# Structured to compare the two invocations directly. RED-or-PASS depending on
# current behavior; either way it must not differ between calls.
idem_double_call() {
  run_with_timeout 30 node -e "
    const {collectBashWriteTargets}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const ir=parse(process.argv[1]);
    try {
      const a=JSON.stringify(collectBashWriteTargets(ir));
      const b=JSON.stringify(collectBashWriteTargets(ir));
      process.stdout.write(a === b ? 'identical' : ('DIFF:'+a+'|'+b));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}
assert_eq "IDEM1 collectBashWriteTargets twice on same IR → identical" "identical" "$(idem_double_call 'rm /tmp/foo')"

echo "=== SC: scope helpers over typed targets (RED-pending-impl) ==="
# areAllBashTargetsOutsideSessionScope: self-target uses repoRoot DIRECTLY (no
# findRepoRoot double-resolution); ancestor behaves identically to the pre-impl
# bare-string path. We drive the real helper with a typed target array and a
# sessionRoots Set containing the normalized repoRoot.
sc_self_uses_repo_directly() {
  # A {resolveVia:"self", path: repoRoot} target whose path IS an in-session
  # root must make all-outside FALSE (self-target is in scope) WITHOUT calling
  # findRepoRoot on it. Pre-impl the helper indexes bare strings via findRepoRoot,
  # so a plain path that is not a real git repo resolves to null → all-outside
  # TRUE. Post-impl the self branch treats path as the root → in-scope → FALSE.
  run_with_timeout 30 node -e "
    const {areAllBashTargetsOutsideSessionScope}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {normalizeForCompare}=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const root='/fake/session/root';
    const roots=new Set([normalizeForCompare(root)]);
    const targets=[{resolveVia:'self', path: root}];
    try { process.stdout.write(String(areAllBashTargetsOutsideSessionScope(targets, roots))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " 2>/dev/null
}
# Expected post-impl: false (self-target is in scope → NOT all-outside).
assert_eq "SC1 self-target uses repoRoot directly (in-scope → all-outside false)" "false" "$(sc_self_uses_repo_directly)"

sc_self_outside_scope() {
  # Positive counterpart to SC1: a {resolveVia:"self", path} target whose path is
  # NOT in sessionRoots must make all-outside TRUE (all targets outside → allow).
  # This guards against an inverted / off-by-one self-path condition: the self
  # branch must use t.path as the root and compare against sessionRoots, returning
  # true when the root is absent from the set. Pre-impl the typed-target self branch
  # is not implemented → RED-pending.
  run_with_timeout 30 node -e "
    const {areAllBashTargetsOutsideSessionScope}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {normalizeForCompare}=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const roots=new Set([normalizeForCompare('/fake/session/root')]);
    const targets=[{resolveVia:'self', path: '/other/outside/root'}];
    try { process.stdout.write(String(areAllBashTargetsOutsideSessionScope(targets, roots))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " 2>/dev/null
}
# Expected post-impl: true (self-target outside session roots → all-outside).
assert_eq "SC1b self-target OUTSIDE session roots (all-outside true)" "true" "$(sc_self_outside_scope)"

sc_ancestor_matches_bare() {
  # {resolveVia:"ancestor", path: WORKTREE} — WORKTREE is a real git repo (this
  # agents worktree). With sessionRoots = {normalized WORKTREE root}, the
  # ancestor branch runs findRepoRoot(path) and finds it in scope → all-outside
  # FALSE. This mirrors the pre-impl bare-string behavior for a real repo path.
  run_with_timeout 30 node -e "
    const {areAllBashTargetsOutsideSessionScope}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {findRepoRoot,normalizeForCompare}=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const p=process.argv[1];
    const root=findRepoRoot(p);
    const roots=new Set([normalizeForCompare(root)]);
    const targets=[{resolveVia:'ancestor', path: p}];
    try { process.stdout.write(String(areAllBashTargetsOutsideSessionScope(targets, roots))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "${WT_NODE}/README.md" 2>/dev/null
}
assert_eq "SC2 ancestor-target matches bare-string behavior (in-scope → all-outside false)" "false" "$(sc_ancestor_matches_bare)"

sc_plansdir_reads_path() {
  # areAllBashTargetsUnderPlansDir reads .path (quoted / $VAR plans-dir targets
  # still resolve). Drive with a typed target whose path is under plans-dir.
  run_with_timeout 30 node -e "
    const {areAllBashTargetsUnderPlansDir}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {getWorkflowPlansDir}=require('${WT_NODE}/hooks/lib/workflow-plans-dir');
    const path=require('path');
    let pd; try { pd=getWorkflowPlansDir(); } catch(_) { process.stdout.write('ERROR:no-plans-dir'); process.exit(0); }
    const target=[{resolveVia:'ancestor', path: path.join(pd,'f.json')}];
    try { process.stdout.write(String(areAllBashTargetsUnderPlansDir(target))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " 2>/dev/null
}
assert_eq "SC3 areAllBashTargetsUnderPlansDir reads .path (plans-dir target true)" "true" "$(sc_plansdir_reads_path)"

sc_plansdir_reads_path_neg() {
  # Negative sibling: a .path OUTSIDE plans-dir must return false — proves the
  # helper actually reads .path and evaluates it, not a blanket true.
  run_with_timeout 30 node -e "
    const {areAllBashTargetsUnderPlansDir}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const target=[{resolveVia:'ancestor', path: '/tmp/definitely-not-plans/f'}];
    try { process.stdout.write(String(areAllBashTargetsUnderPlansDir(target))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " 2>/dev/null
}
assert_eq "SC4 areAllBashTargetsUnderPlansDir .path outside plans-dir false" "false" "$(sc_plansdir_reads_path_neg)"

echo "=== BLK: block-* hooks still block protected paths via .path (PASS now/RED-pending) ==="
# The block-shell-config / block-history / block-memory hooks read the collector
# output. Post-migration they must read t.path. We assert the decision at the
# hook boundary: a write to a protected path (e.g. ~/.bashrc, docs/history.md,
# CLAUDE memory) is blocked. This is behavior-neutral (blocked both before and
# after), so it is a preservation pin.
call_block_hook() {
  local hook="$1" cmd="$2"
  local ev
  ev="$(run_with_timeout 30 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash', tool_input:{command: process.argv[1]}}))" -- "$cmd" 2>/dev/null)"
  (cd "$WORKTREE" && printf '%s' "$ev" | run_with_timeout 30 node "hooks/$hook" 2>/dev/null) \
    | run_with_timeout 30 node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{process.stdout.write(String(JSON.parse(s).decision))}catch(_){process.stdout.write('none')}})" 2>/dev/null
}
# These are PRESERVATION pins: the hooks call collectWriteTargetsFromSegments
# and, after the Commit 1 migration, must read t.path from the typed targets.
# The decision must stay identical (block on protected, approve otherwise).
HOME_FS="$(run_with_timeout 30 node -e 'process.stdout.write(require("os").homedir())' 2>/dev/null)"
MEM_PATH="$HOME_FS/.claude/projects/c--git-agents/memory/MEMORY.md"
# block-shell-config: writing to ~/.bashrc must block.
assert_eq "BLK1 block-shell-config blocks ~/.bashrc redirect" "block" "$(call_block_hook block-shell-config.js 'echo x >> ~/.bashrc')"
# block-history-direct: appending to docs/history.md directly must block.
assert_eq "BLK2 block-history-direct blocks docs/history.md redirect" "block" "$(call_block_hook block-history-direct.js 'echo x >> docs/history.md')"
# block-memory-direct: writing under the real CLAUDE memory dir must block.
assert_eq "BLK3 block-memory-direct blocks memory path redirect" "block" "$(call_block_hook block-memory-direct.js "echo x > $MEM_PATH")"
# Negative sibling: an ordinary path is approved (not blocked) — proves the block
# is path-specific, i.e. the target .path was actually evaluated (hooks fail-open
# to {decision:"approve"} on non-match).
assert_eq "BLK4 block-shell-config approves ordinary path" "approve" "$(call_block_hook block-shell-config.js 'echo x > /tmp/ordinary-file')"

echo "=== L2: enforce-worktree behavior-neutral (Commit 1 changes nothing) ==="
# Green-group writes into an IN-SCOPE main worktree must BLOCK (they reach the
# scope pipeline and are not out-of-session). Behavior-neutral: same decision
# before and after Commit 1. A single-repo main-worktree fixture: cwd repo is
# always a session root, so an in-scope write blocks on the main-checkout gate.
TMP_ROOT="$(mk_tmp_root c1)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

assert_l2_block() {
  local name="$1" cmd="$2"
  local out; out="$(run_bash_guard "$cmd" "$REPO" ENFORCE_WORKTREE=on)"
  if echo "$out" | grep -q '"decision":"block"'; then pass "$name"; else fail "$name — expected block, got ($out)"; fi
}
assert_l2_block "L2-1 redirect into in-scope main blocks" 'echo x > README.md'
assert_l2_block "L2-2 tee into in-scope main blocks"      'echo x | tee README.md'
assert_l2_block "L2-3 cp into in-scope main blocks"       'cp README.md dst.md'
assert_l2_block "L2-4 mv into in-scope main blocks"       'mv README.md dst.md'
assert_l2_block "L2-5 rm in-scope main blocks"            'rm README.md'
assert_l2_block "L2-6 pwsh cmdlet into in-scope main blocks" 'Set-Content README.md -Value x'

report_totals
exit "$FAIL"
