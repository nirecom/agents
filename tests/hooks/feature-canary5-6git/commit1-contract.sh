#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/commit1-contract.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/enforce-worktree/bash-write-scope.js, hooks/block-shell-config.js, hooks/block-history-direct.js, hooks/block-memory-direct.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, typed-target, contract-migration, scope:issue-specific, hook-registration, pwsh-not-required
#
# Commit 1 — typed {resolveVia,path} contract (behavior-neutral de-risk): S* pin
# the collector's typed wrap (D1); P*, BLK*, L2 pin preserved behavior.
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js / block-*.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bq_hdr "=== S: collectWriteTargetsFromSegments typed shape (RED-pending-impl) ==="
# Post-impl each collected target is {resolveVia:"ancestor", path:"/tmp/..."}.
# Pre-impl it is the bare string → FAIL now (correct fail-before-impl evidence).
case_begin "c1-collector-typed-shape" "hooks/lib/bash-write-targets.js"
bq_table collect_first <<'S_TABLE'
S1 redirect typed shape^printf x > /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S2 tee typed shape^cat x | tee /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S3 pwsh typed shape^Out-File -FilePath /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S4 cp typed shape^cp src /tmp/dest^{"resolveVia":"ancestor","path":"/tmp/dest"}
S5 mv typed shape^mv a /tmp/dest^{"resolveVia":"ancestor","path":"/tmp/dest"}
S6 rm typed shape^rm /tmp/foo^{"resolveVia":"ancestor","path":"/tmp/foo"}
S_TABLE
case_end

bq_hdr "=== P: extractor string-API return pins (PASS now — proves wrap is at collector, D1) ==="
# The 5 extractors keep their bare string[] / string public API. If the impl
# wrongly wrapped inside the extractor, these would break — proving the wrap
# lives in the collector (D1), not the extractors.
case_begin "c1-extractor-string-api" "hooks/lib/bash-write-targets.js"
bq_row "P1 redirect string API bare array" '["/tmp/foo"]'  extractor_str redirect extractRedirectTargets 'printf x > /tmp/foo'
bq_row "P2 tee string API bare array"       '["/tmp/foo"]'  extractor_str tee extractTeeTargets 'echo x | tee /tmp/foo'
bq_row "P3 pwsh string API bare array"      '["/tmp/foo"]'  extractor_str pwsh extractPwshWriteTargets 'Out-File -FilePath /tmp/foo'
bq_row "P4 cp-mv string API bare string"    '"/tmp/dest"'   extractor_str cp-mv extractCpMvDestination 'cp src /tmp/dest'
bq_row "P5 rm string API bare array"        '["/tmp/foo"]'  extractor_str rm extractRmTargets 'rm /tmp/foo'
case_end

bq_hdr "=== IDEM: collectBashWriteTargets idempotency (no state mutation) ==="
# Calling collectBashWriteTargets twice on the SAME ir object must return
# identical results — no caching side effects, no in-place mutation of the ir.
case_begin "c1-collect-idempotent" "hooks/enforce-worktree/bash-write-scope.js"
bq_row "IDEM1 collectBashWriteTargets twice on same IR → identical" "identical" idem 'rm /tmp/foo'
case_end

bq_hdr "=== SC: scope helpers over typed targets (RED-pending-impl) ==="
# SC1: a {resolveVia:"self"} target whose path IS an in-session root is in scope
# WITHOUT findRepoRoot double-resolution → all-outside FALSE. SC1b is the
# positive counterpart (self path absent from sessionRoots → all-outside TRUE),
# guarding an inverted self-path condition.
case_begin "c1-scope-helpers-typed" "hooks/enforce-worktree/bash-write-scope.js"
bq_row "SC1 self-target uses repoRoot directly (in-scope → all-outside false)" "false" sc_self /fake/session/root /fake/session/root
bq_row "SC1b self-target OUTSIDE session roots (all-outside true)" "true" sc_self /fake/session/root /other/outside/root
# SC2: {resolveVia:"ancestor", path:<this worktree>} with sessionRoots = its own
# repo root → in scope → FALSE (mirrors the pre-impl bare-string behavior).
bq_row "SC2 ancestor-target matches bare-string behavior (in-scope → all-outside false)" "false" sc_ancestor "${WT_NODE}/README.md"
# SC3/SC4: areAllBashTargetsUnderPlansDir reads .path — a plans-dir target is
# true; the negative sibling (outside plans-dir) proves it is not a blanket true.
bq_row "SC3 areAllBashTargetsUnderPlansDir reads .path (plans-dir target true)" "true" sc_plans_pd
bq_row "SC4 areAllBashTargetsUnderPlansDir .path outside plans-dir false" "false" sc_plans /tmp/definitely-not-plans/f
case_end

bq_hdr "=== BLK: block-* hooks still block protected paths via .path (PASS now/RED-pending) ==="
# PRESERVATION pins: block-shell-config / block-history / block-memory read t.path
# from the collector; a protected-path write blocks, an ordinary path approves
# (hooks fail-open to {decision:"approve"}). @HOME@ = os.homedir() in the driver.
case_begin "c1-block-shell-config-protected" "hooks/block-shell-config.js"
bq_row "BLK1 block-shell-config blocks ~/.bashrc redirect" "block" blockhook block-shell-config.js 'echo x >> ~/.bashrc'
case_end
case_begin "c1-block-history-direct" "hooks/block-history-direct.js"
bq_row "BLK2 block-history-direct blocks docs/history.md redirect" "block" blockhook block-history-direct.js 'echo x >> docs/history.md'
case_end
case_begin "c1-block-memory-direct" "hooks/block-memory-direct.js"
bq_row "BLK3 block-memory-direct blocks memory path redirect" "block" blockhook block-memory-direct.js 'echo x > @HOME@/.claude/projects/c--git-agents/memory/MEMORY.md'
case_end
case_begin "c1-block-shell-config-ordinary" "hooks/block-shell-config.js"
bq_row "BLK4 block-shell-config approves ordinary path" "approve" blockhook block-shell-config.js 'echo x > /tmp/ordinary-file'
case_end

bq_hdr "=== L2: enforce-worktree behavior-neutral (Commit 1 changes nothing) ==="
# Green-group writes into an IN-SCOPE main worktree must BLOCK (cwd repo is
# always a session root → main-checkout gate). Same decision before/after.
TMP_ROOT="$(mk_tmp_root c1)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

case_begin "c1-l2-main-worktree-block" "hooks/enforce-worktree.js"
bq_row "L2-1 redirect into in-scope main blocks" block guard "$REPO" 'echo x > README.md'
bq_row "L2-2 tee into in-scope main blocks"      block guard "$REPO" 'echo x | tee README.md'
bq_row "L2-3 cp into in-scope main blocks"       block guard "$REPO" 'cp README.md dst.md'
bq_row "L2-4 mv into in-scope main blocks"       block guard "$REPO" 'mv README.md dst.md'
bq_row "L2-5 rm in-scope main blocks"            block guard "$REPO" 'rm README.md'
bq_row "L2-6 pwsh cmdlet into in-scope main blocks" block guard "$REPO" 'Set-Content README.md -Value x'
case_end
bq_flush

report_totals
exit "$FAIL"
