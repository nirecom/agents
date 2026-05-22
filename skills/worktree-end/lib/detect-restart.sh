#!/usr/bin/env bash
# skills/worktree-end/lib/detect-restart.sh
# Detect whether merged PR contains Claude Code config changes requiring restart.
# Outputs "yes" or "no" to stdout. Always exits 0 (fail-safe to "no").
# Args: $1 = PR_NUMBER
# Env: AGENTS_CONFIG_DIR (non-empty = agents repo session; otherwise output "no")
# Requires: gh CLI on PATH, authenticated.
#
# Fail-safe policy: any gh failure (auth lost, network error, etc.) results in "no".
# Rationale: false-negative (missed restart prompt) has lower impact than
# false-positive (urging an unnecessary restart).
set -euo pipefail

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ] || [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
  echo "no"
  exit 0
fi

# Stage 1: file-list scan (lightweight; one gh API call).
# gh pr view --json files fetches via GitHub API and is independent of local
# branch state — squash-merge does not break it.
CC_FILES=$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null || true)

# Top-level CLAUDE*.md or anything under rules/ → unconditional yes.
if printf '%s\n' "$CC_FILES" | grep -qE '^(CLAUDE\.md|CLAUDE\.local\.md|rules/.+)$'; then
  echo "yes"
  exit 0
fi

# Stage 2: settings.json scan — only when a relevant settings file changed.
# In the agents repo, settings files live at the repo root:
#   settings.json         → symlinked as ~/.claude/settings.json
#   settings-extension.json → VS Code extension settings (may contain model key)
if printf '%s\n' "$CC_FILES" | grep -qE '^settings(-extension)?\.json$'; then
  # gh pr diff retrieves the diff via GitHub API; works after squash-merge.
  # Capture to variable first to avoid grep -q early-exit triggering SIGPIPE on
  # gh pr diff under set -o pipefail, which would evaluate the pipeline as failure
  # even when grep found a match.
  CC_DIFF=$(gh pr diff "$PR_NUMBER" 2>/dev/null || true)
  if printf '%s\n' "$CC_DIFF" | grep -qE '^[+-][[:space:]]*"(model|outputStyle)"[[:space:]]*:'; then
    echo "yes"
    exit 0
  fi
fi

echo "no"
