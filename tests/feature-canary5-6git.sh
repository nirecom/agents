#!/usr/bin/env bash
# tests/feature-canary5-6git.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/bash-write-targets/git.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, classify, write-patterns, ir-migration, git-write, scope:issue-specific, hook-registration, pwsh-not-required, security
#
# Dispatcher for the WRITE_PATTERNS → IR migration suite (#1400 canary-5 +
# #1401 canary-6-git). Runs three part files, one per commit stage. This file
# is >300 lines when combined, so it is split per rules/coding/file-split.md
# (canonical example: tests/main-workflow-skip-sentinels/).
#
# pwsh-not-required: the pwsh-cmdlet cases (Set-Content/Out-File/...) drive
# node classify()/predicates over parsed IR — no real pwsh shell is spawned, so
# no pwsh runtime is exercised.
#
# L3 gap (applies to every L2 case below): real PreToolUse dispatch only fires
# inside a live `claude -p` session via the Anthropic hook protocol. These L2
# cases drive `node hooks/enforce-worktree.js` over stdin JSON, not the real
# hook dispatch. Live-session env (ENFORCE_WORKTREE, ADDITIONAL_REPOS) and
# Windows backslash normalization of model-emitted git `-C` paths passed through
# a real shell differ from these shell-normalized fixtures. Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight bin/check-verification-gate.sh
# category: hook-registration.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE="$(cd "$DIR/.." && pwd)"
PARTS_DIR="$DIR/feature-canary5-6git"

TOTAL_FAIL=0
for part in commit1-contract commit2-green-retire commit3-git gaps-adversarial convergence-broad-failclose shell-layer-exotic; do
  echo "########################################################"
  echo "## $part"
  echo "########################################################"
  bash "$PARTS_DIR/$part.sh" "$WORKTREE"
  rc=$?
  if [ "$rc" -eq 77 ]; then
    echo "SKIP: $part exited 77 (dependency missing)"
  elif [ "$rc" -ne 0 ]; then
    TOTAL_FAIL=$((TOTAL_FAIL + rc))
  fi
done

echo ""
echo "======================================================="
echo "Suite TOTAL_FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -gt 0 ] && exit 1
exit 0
