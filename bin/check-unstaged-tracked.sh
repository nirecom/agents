#!/usr/bin/env bash
# Thin wrapper: delegates to hooks/workflow-gate/staged-evidence.js#hasUnstagedTrackedChanges
# (the SSOT for tracked-vs-unstaged detection, also used by workflow-gate.js PreToolUse hook).
# The bash front exists because /worktree-end, /commit-push, and the commit-push worker module need a CLI entry point;
# the actual logic lives in node so workflow-gate.js can call it without spawning a subprocess.
# Exit codes: 0=clean, 1=dirty (file list on stdout), 2=usage error, 3=internal error (fail-safe — caller must abort).
# See issue #269 for the 3-gate defense-in-depth rationale.

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  TARGET_CHECKOUT_ROOT="$PWD"
elif [ "$#" -eq 1 ]; then
  TARGET_CHECKOUT_ROOT="$1"
else
  echo "Usage: check-unstaged-tracked.sh [repo-dir]" >&2
  exit 2
fi

HELPER_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/staged-evidence.js"

rc=0
node -e '
  const { hasUnstagedTrackedChanges } = require(process.argv[1]);
  const r = hasUnstagedTrackedChanges(process.argv[2]);
  if (r.error !== null) { process.stderr.write(r.error + "\n"); process.exit(3); }
  if (r.hasChanges) { process.stdout.write(r.files.join("\n") + "\n"); process.exit(1); }
  process.exit(0);
' "$HELPER_JS" "$TARGET_CHECKOUT_ROOT" || rc=$?

case "$rc" in
  0|1|2|3) exit "$rc" ;;
  *) echo "check-unstaged-tracked: node helper failed (exit=$rc)" >&2; exit 3 ;;
esac
