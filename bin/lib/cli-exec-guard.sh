#!/usr/bin/env bash
# Pre-exec guards shared by the LLM CLI wrappers (codex-core.sh, gemini-core.sh).
# Source this file; it defines functions and constants only and never exits the caller.
# CODEX_INPUT_CHAR_LIMIT: the codex stdin limit (code points) every codex launch path checks against.
# cli_exec_guard_input_size <file> <limit>: counts code points with node (locale-free);
#   0 = within limit, 1 = "input too large: ...", 2 = "input size check failed: ..." (fail-closed).
# cli_exec_guard_diagnose_127 <cli>: one-line cause for a `timeout <cli>` exit 127.

# shellcheck disable=SC2034  # consumed by the sourcing launchers
CODEX_INPUT_CHAR_LIMIT=1048576

cli_exec_guard_input_size() {
  local file="$1" limit="$2" count rc=0 err
  if [[ ! -r "$file" ]]; then
    echo "input size check failed: cannot read ${file}"
    return 2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "input size check failed: node not found on PATH"
    return 2
  fi
  count="$(node -e 'let n = 0; for (const _ of require("fs").readFileSync(0, "utf8")) n++; process.stdout.write(String(n));' < "$file" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || ! "$count" =~ ^[0-9]+$ ]]; then
    # Prefer the *Error: line over a leading stack location (uncaught node exception).
    err="$(printf '%s\n' "$count" | grep -m1 -E '^[A-Za-z]*Error:' || printf '%s' "${count%%$'\n'*}")"
    echo "input size check failed: node exit ${rc}: ${err}"
    return 2
  fi
  if (( count > limit )); then
    echo "input too large: ${count} chars > limit ${limit}"
    return 1
  fi
  return 0
}

cli_exec_guard_diagnose_127() {
  local cli="$1" cli_path env_bytes
  if ! command -v timeout >/dev/null 2>&1; then
    echo "exit 127: 'timeout' not found on PATH"
    return 0
  fi
  if ! cli_path="$(command -v "$cli" 2>/dev/null)"; then
    echo "exit 127: '${cli}' executable not found on PATH at exec time"
    return 0
  fi
  env_bytes="$(env | wc -c)"
  echo "exit 127: '${cli}' resolves in parent (${cli_path}) but the child failed to start — child environment likely broken (exported env ${env_bytes//[[:space:]]/} bytes; oversized exported variable or lost PATH)"
}
