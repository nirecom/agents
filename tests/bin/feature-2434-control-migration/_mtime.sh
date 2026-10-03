#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/_mtime.sh
# Tests: hooks/lib/temporary-migrations/control-dir-split/index.js
# Tags: TL2, scope:issue-specific, control-dir, migration, test-helper
# Shared mtime helpers for the feature-2434-control-migration parts (sourced, not run).
# Node with np()-normalized paths, because python3 on Windows cannot open MSYS paths
# (/c/...): the old inline python3 calls failed silently behind `|| true`, so "aged"
# fixtures were never aged and mtime reads returned 0. Requires tests/lib/harness.sh.
# file_mtime <path> -> integer seconds, or 0 when unreadable
file_mtime() {
  node -e "try{process.stdout.write(String(Math.floor(require('fs').statSync(process.argv[1]).mtimeMs/1000)))}catch(e){process.stdout.write('0')}" "$(np "$1")"
}

# age_files <seconds-ago> <path>... -> sets atime/mtime into the past; fails loudly
age_files() {
  local ago="$1"; shift
  local p args=()
  for p in "$@"; do args+=("$(np "$p")"); done
  node -e "const fs=require('fs');const t=Date.now()/1000-Number(process.argv[1]);for(const p of process.argv.slice(2)){fs.utimesSync(p,t,t)}" "$ago" "${args[@]}" \
    || echo "age_files: could not age $* (fixture is not aged)" >&2
}
