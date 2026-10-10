#!/usr/bin/env bash
# Probe whether a remote repo is in pre-bootstrap state (no default branch).
# Usage: probe-remote-bootstrap.sh <repo-root>
# Output: JSON object from isRemoteInPreBootstrap — always exits 0.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="${1:?probe-remote-bootstrap.sh: repo-root argument required}"
node -e '
  const m = require(process.argv[2]);
  const r = m.isRemoteInPreBootstrap(process.argv[1]);
  process.stdout.write(JSON.stringify(r));
' "$repo_root" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/bootstrap-state.js"
