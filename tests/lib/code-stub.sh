#!/usr/bin/env bash
# tests/lib/code-stub.sh
# Tests: tests/lib/code-stub.sh
# Tags: scope:issue-specific, shared-lib, plan-sync, vscode, stub
# #2513 `code` executable stub: every editor launch appends one line to CODE_STUB_LOG,
# so a test can assert that plan display / confirmation never auto-opens VS Code.
# Defines only code_stub_* / setup_code_stub; call them inside a subshell (PATH is changed).
CODE_STUB_DIR=""

# setup_code_stub <dir> — writes `code` (POSIX spawn) and `code.cmd` (win32 `cmd.exe /c code`)
# into <dir>, prepends <dir> to PATH, exports CODE_STUB_LOG and its native form CODE_STUB_LOG_WIN.
setup_code_stub() {
  CODE_STUB_DIR="$1"
  mkdir -p "$CODE_STUB_DIR" || return 1
  export CODE_STUB_LOG="$CODE_STUB_DIR/code-stub.log"
  : > "$CODE_STUB_LOG" || return 1
  export CODE_STUB_LOG_WIN="$CODE_STUB_LOG"
  local path_entry="$CODE_STUB_DIR"
  if command -v cygpath >/dev/null 2>&1; then
    CODE_STUB_LOG_WIN="$(cygpath -w "$CODE_STUB_LOG")"
    path_entry="$(cygpath -u "$CODE_STUB_DIR")"
  fi
  printf '%s\n' '#!/bin/sh' 'echo "code $*" >> "$CODE_STUB_LOG"' > "$CODE_STUB_DIR/code" || return 1
  chmod +x "$CODE_STUB_DIR/code"
  printf '%s\r\n' '@echo off' 'echo code %*>>"%CODE_STUB_LOG_WIN%"' > "$CODE_STUB_DIR/code.cmd" || return 1
  export PATH="$path_entry:$PATH"
}

# code_stub_count — number of recorded launches (0 when the log is missing).
code_stub_count() {
  local n=0
  [ -f "$CODE_STUB_LOG" ] && n="$(wc -l < "$CODE_STUB_LOG")"
  printf '%s' "$((n + 0))"
}

# code_stub_is_windows — Git Bash / MSYS / Cygwin host. Never keyed on OS: the test-runner
# worker's env allowlist strips it, while OSTYPE is a bash builtin and survives `env -i`.
code_stub_is_windows() {
  case "${OSTYPE:-}" in msys* | cygwin* | win32*) return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
  return 1
}

# code_stub_resolves — `code` as a spawned child would resolve it is the stub (never the real editor).
# win32: both sides go through realpathSync.native, since `where` prints long names while the
# stub dir may carry an 8.3 short name (TEMP=C:\...\LONGDI~1), plus case and slash differences.
code_stub_resolves() {
  if code_stub_is_windows; then
    CODE_STUB_DIR_NATIVE="$(cygpath -m "$CODE_STUB_DIR")" node -e '
const fs = require("fs"), path = require("path");
const r = require("child_process").spawnSync("cmd.exe", ["/d", "/s", "/c", "where", "code"], { encoding: "utf8" });
const first = ((r.stdout || "").split(/\r?\n/)[0] || "").trim();
const canon = (p) => { try { return fs.realpathSync.native(p).replace(/\\/g, "/").toLowerCase(); } catch (e) { return ""; } };
const base = path.win32.basename(first).toLowerCase();
const got = first ? canon(path.win32.dirname(first)) : "";
const want = canon(process.env.CODE_STUB_DIR_NATIVE || "");
process.exit(got !== "" && got === want && (base === "code" || base === "code.cmd") ? 0 : 1);'
    return
  fi
  [[ "$(command -v code)" == "$CODE_STUB_DIR/code" ]]
}

# code_stub_probe — positive control: resolves to the stub AND a spawn the way the old
# auto-open did it is recorded exactly once; the log is truncated afterwards.
code_stub_probe() {
  code_stub_resolves || return 1
  node -e "const cp = require('child_process');
if (process.platform === 'win32') cp.spawnSync('cmd.exe', ['/d', '/s', '/c', 'code', '--stub-probe'], { stdio: 'ignore', windowsHide: true });
else cp.spawnSync('code', ['--stub-probe'], { stdio: 'ignore' });" || return 1
  [ "$(code_stub_count)" = "1" ] || return 1
  : > "$CODE_STUB_LOG"
}
