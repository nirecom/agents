#!/usr/bin/env bash
# tests/lib/cli-stub.sh
# Tests: tests/lib/cli-stub.sh
# Tags: scope:issue-specific, shared-lib, cli-stub, gh-stub, glab-stub, visibility
# Sourced PATH stub for a forge CLI (gh, glab), reachable from Node with or without a shell (#2513).

# Node's shell-less spawnSync resolves only .exe/.com on Windows (a .cmd is invisible), so
# <name>(.exe) are links/copies of the node binary; the preload answers as the stub when
# its own basename is a stub name and stays inert in every other node process.
# Per-call vars: CLI_STUB_OUT (stdout), CLI_STUB_RC (exit code),
# CLI_STUB_SLEEP_MS (delay before answering), CLI_STUB_LOG (appends "<name> <args>").

cli_stub_make() { # <dir> <name>... — sets CLI_STUB_DIR (PATH form) and CLI_STUB_PRELOAD.
  local d="$1" node_bin n names
  shift
  mkdir -p "$d" || return 1
  node_bin="$(node -p 'process.execPath')" || return 1
  for n in "$@"; do
    # MSYS ln/cp append .exe on their own, so <name>.exe may already exist.
    [ -e "$d/$n" ] || ln "$node_bin" "$d/$n" 2>/dev/null || cp "$node_bin" "$d/$n" || return 1
    [ -e "$d/$n.exe" ] || ln "$node_bin" "$d/$n.exe" 2>/dev/null || cp "$node_bin" "$d/$n.exe" || return 1
  done
  names="$(IFS=,; printf '%s' "$*")"
  printf '%s\n' 'const path = require("path"); const fs = require("fs");' \
    "const NAMES = \"$names\".split(\",\");" \
    'const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();' \
    'const me = [base(process.execPath), base(process.argv0)].find((b) => NAMES.includes(b));' \
    'if (me) {' \
    '  const a = process.argv.slice(1); if (a.length) a[0] = path.basename(a[0]);' \
    '  if (process.env.CLI_STUB_LOG) fs.appendFileSync(process.env.CLI_STUB_LOG, [me].concat(a).join(" ") + "\n");' \
    '  const ms = Number(process.env.CLI_STUB_SLEEP_MS || 0);' \
    '  if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);' \
    '  fs.writeSync(1, process.env.CLI_STUB_OUT || "");' \
    '  process.exit(Number(process.env.CLI_STUB_RC || 0));' \
    '}' > "$d/cli-stub-preload.js" || return 1
  if command -v cygpath >/dev/null 2>&1; then
    CLI_STUB_DIR="$(cygpath -u "$d")"; CLI_STUB_PRELOAD="$(cygpath -m "$d/cli-stub-preload.js")"
  else
    CLI_STUB_DIR="$d"; CLI_STUB_PRELOAD="$d/cli-stub-preload.js"
  fi
}

cli_stub_run() { # <cmd...> — stub first on PATH, preload on, CLI_STUB_* vars exported.
  PATH="$CLI_STUB_DIR:$PATH" NODE_OPTIONS="--require \"$CLI_STUB_PRELOAD\"" \
    CLI_STUB_OUT="${CLI_STUB_OUT:-}" CLI_STUB_RC="${CLI_STUB_RC:-0}" \
    CLI_STUB_SLEEP_MS="${CLI_STUB_SLEEP_MS:-0}" CLI_STUB_LOG="${CLI_STUB_LOG:-}" "$@"
}
