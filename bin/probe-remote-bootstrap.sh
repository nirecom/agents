#!/usr/bin/env bash
# Probe whether a remote repo is in pre-bootstrap state (no default branch).
# Usage: probe-remote-bootstrap.sh <repo-root>
# Output: JSON object from isRemoteInPreBootstrap — always exits 0.
set -euo pipefail
repo_root="${1:?probe-remote-bootstrap.sh: repo-root argument required}"
if [[ -z "${AGENTS_CONFIG_DIR:-}" ]]; then
  printf '{"preBootstrap":false,"classification":"spawn-error","reason":"AGENTS_CONFIG_DIR not set"}\n'
  exit 0
fi
node -e '
  const m = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/bootstrap-state.js");
  const r = m.isRemoteInPreBootstrap(process.argv[1]);
  process.stdout.write(JSON.stringify(r));
' "$repo_root"
