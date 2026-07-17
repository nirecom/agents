#!/usr/bin/env bash
# Thin wrapper: delegates to hooks/workflow-gate/staged-evidence.js#hasUnstagedTrackedChanges
# (the SSOT for tracked-vs-unstaged detection, also used by workflow-gate.js PreToolUse hook).
# The bash front exists because /worktree-end, /commit-push, and commit-push-worker need a CLI entry point;
# the actual logic lives in node so workflow-gate.js can call it without spawning a subprocess.
# Exit codes: 0=clean, 1=dirty (file list on stdout), 2=usage error, 3=internal error (fail-safe — caller must abort).
# See issue #269 for the 3-gate defense-in-depth rationale.

set -euo pipefail

if [ "$#" -eq 0 ]; then
  REPO_DIR="$PWD"
elif [ "$#" -eq 1 ]; then
  REPO_DIR="$1"
else
  echo "Usage: check-unstaged-tracked.sh [repo-dir]" >&2
  exit 2
fi

: "${AGENTS_CONFIG_DIR:=$(cd "$(dirname "$0")/.." && pwd)}"

HELPER_JS="$AGENTS_CONFIG_DIR/hooks/workflow-gate/staged-evidence.js"

rc=0
HELPER_JS="$HELPER_JS" REPO_DIR="$REPO_DIR" node -e '
  const { hasUnstagedTrackedChanges } = require(process.env.HELPER_JS);
  const r = hasUnstagedTrackedChanges(process.env.REPO_DIR);
  if (r.error !== null) { process.stderr.write(r.error + "\n"); process.exit(3); }
  if (r.hasChanges) { process.stdout.write(r.files.join("\n") + "\n"); process.exit(1); }
  process.exit(0);
' || rc=$?

case "$rc" in
  0|1|2|3) exit "$rc" ;;
  *) echo "check-unstaged-tracked: node helper failed (exit=$rc)" >&2; exit 3 ;;
esac
