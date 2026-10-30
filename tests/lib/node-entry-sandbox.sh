#!/usr/bin/env bash
# tests/lib/node-entry-sandbox.sh — sourced. Copies entry points of this checkout plus the Node
# code they run into a sandbox tree (#2507): the bash entries are thin adapters that exec a
# Node module next to them, so copying the bash file alone leaves a sandbox that fails closed.
#   node_entry_sandbox_copy <dest-root> <repo-relative entry>...
# The copy set is computed by tests/lib/node-entry-sandbox.js; returns its exit code.

_NODE_ENTRY_SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_node_entry_sandbox_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

node_entry_sandbox_copy() {
  local dest="${1:?node_entry_sandbox_copy: dest-root required}"
  shift
  node "$(_node_entry_sandbox_native "$_NODE_ENTRY_SANDBOX_ROOT/tests/lib/node-entry-sandbox.js")" \
    "$(_node_entry_sandbox_native "$_NODE_ENTRY_SANDBOX_ROOT")" "$(_node_entry_sandbox_native "$dest")" "$@"
}
