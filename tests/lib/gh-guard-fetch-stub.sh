#!/usr/bin/env bash
# tests/lib/gh-guard-fetch-stub.sh — answers bin/user-block-guard's `gh api graphql` old-state read (#2940).
# Why: the guard runs `gh` through node's spawnSync, which on Windows finds only a gh.exe, never a
# bash `gh` mock. This installs tests/lib/gh-scripted-stub.js's gh.exe (plus the NODE_OPTIONS
# preload) answering `api graphql` with an issue whose body has NO `<user>` block, so the guard allows.
# Usage: source this file, then call `gh_guard_fetch_stub_install <dir>` BEFORE prepending the
# test's own bash gh mock to PATH (the bash mock must stay first; the stub only serves the guard).
# Exports PATH, NODE_OPTIONS, F2940_GH_SPEC, F2940_GH_LOG, GH_GUARD_STUB_BIN (the stub's bin dir).

_GGFS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gh_guard_fetch_stub_install() {
  local dir="$1" mixed out stub_bin preload issue
  mkdir -p "$dir"
  mixed="$dir"
  command -v cygpath >/dev/null 2>&1 && mixed="$(cygpath -m "$dir")"
  out="$(node "$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$_GGFS_LIB_DIR/gh-scripted-stub.js" || echo "$_GGFS_LIB_DIR/gh-scripted-stub.js")" setup "$mixed/guard-stub")"
  stub_bin="${out%%$'\n'*}"
  preload="${out#*$'\n'}"
  command -v cygpath >/dev/null 2>&1 && stub_bin="$(cygpath -u "$stub_bin")"
  issue='{"id":"I_stub","__typename":"Issue","title":"Stub issue","body":"Stub body without a user block","comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}'
  # Second rule: the REST read of a numeric comment (fetchRestComment) — also without a <user> block.
  printf '{"rules":[{"match":"^api graphql","stdout":{"data":{"repository":{"issue":%s},"node":%s}}},{"match":"^api repos/[^ ]+/issues/comments/[0-9]+$","stdout":{"id":1,"body":"Stub comment without a user block"}}],"fallback":{"exit":0}}\n' "$issue" "$issue" >"$dir/guard-stub-spec.json"
  export F2940_GH_SPEC="$mixed/guard-stub-spec.json"
  export F2940_GH_LOG="$mixed/guard-stub-calls.jsonl"
  export NODE_OPTIONS="${NODE_OPTIONS:-} --require \"$preload\""
  export PATH="$stub_bin:$PATH"
  # Absolute route to the stub for the tests' bash gh mocks: on POSIX the mock sits earlier in PATH
  # than the stub, so the mock forwards the guard's reads to "$GH_GUARD_STUB_BIN/gh" (an executable bash script).
  export GH_GUARD_STUB_BIN="$stub_bin"
}

# gh_guard_forward_snippet — documents the forward each bash gh mock performs (kept in the mocks themselves):
#   case "$*" in
#     api\ graphql\ *'query($owner:String!'*|api\ graphql\ *'query($id:ID!'*|api\ repos/*/issues/comments/[0-9]*)
#       [ -n "${GH_GUARD_STUB_BIN:-}" ] && exec "$GH_GUARD_STUB_BIN/gh" "$@" ;;
#   esac
