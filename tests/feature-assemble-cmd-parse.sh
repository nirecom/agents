#!/usr/bin/env bash
# Tests: hooks/lib/assemble-cmd-parse.js, skills/_shared/assemble-mandatory.sh
# Tags: hook, skill, bin, windows, macos
# Tests for hooks/lib/assemble-cmd-parse.js — pure function extractAssembleDest(cmd).
#
# Contract: given a Bash command string that may invoke assemble-mandatory.sh,
# return the destination path (the 3rd positional argument after the script),
# or null when the command does not invoke the script or has malformed args.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
LIB="$AGENTS_DIR/hooks/lib/assemble-cmd-parse.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (rules/test-rules/macos-timeout.md)
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# Use node os.tmpdir() for T9/T10 paths so MSYS2 does not convert POSIX-style
# /tmp/ paths in env vars when they are passed to native node.exe on Windows.
# Backslash-continuation chars (\<LF>, \<CRLF>) stay intact when adjacent
# paths are already Windows-style (non-POSIX).
NODE_TMPDIR="$(run_with_timeout node -e "process.stdout.write(require('os').tmpdir().replace(/\\\\/g,'/'))")"

if [ ! -f "$LIB" ]; then
  echo "NOTE: source missing: $LIB"
  echo "NOTE: tests below will fail with MODULE_NOT_FOUND until the module is created."
fi

# Helper: pass the command via env var to avoid all shell escaping issues.
# Reads CMD from env and prints JSON of the result.
run_extract() {
  CMD="$1" run_with_timeout node -e "
    const m = require('$LIB');
    const r = m.extractAssembleDest(process.env.CMD);
    process.stdout.write(JSON.stringify(r));
  " 2>/dev/null
}

# Helper: assert result matches expected JSON.
expect_result() {
  local desc="$1" cmd="$2" expected="$3"
  local result
  result=$(run_extract "$cmd")
  if [ "$result" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc — expected $expected got $result"
  fi
}

# ── T1: full path with --source-kind intent ─────────────────────────────────
CMD_T1='"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent /a/intent.md /a/draft.md /tmp/test-outline.md'
expect_result "T1 --source-kind intent — returns 3rd positional (outline.md)" \
  "$CMD_T1" '"/tmp/test-outline.md"'

# ── T2: bash assemble-mandatory.sh --source-kind outline ─────────────────────
CMD_T2='bash assemble-mandatory.sh --source-kind outline /a/outline.md /a/draft.md /b/detail.md'
expect_result "T2 --source-kind outline — returns /b/detail.md" \
  "$CMD_T2" '"/b/detail.md"'

# ── T3: command without assemble-mandatory.sh ────────────────────────────────
CMD_T3='echo hello world'
expect_result "T3 no assemble-mandatory.sh — returns null" \
  "$CMD_T3" 'null'

# ── T4: no --source-kind (bare positionals) ──────────────────────────────────
CMD_T4='assemble-mandatory.sh /a/intent.md /a/draft.md /tmp/test-outline.md'
expect_result "T4 bare positionals — returns 3rd positional" \
  "$CMD_T4" '"/tmp/test-outline.md"'

# ── T5: quoted paths with spaces ─────────────────────────────────────────────
CMD_T5='"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent "/a/path with space/intent.md" "/a/path with space/draft.md" "/a/path with space/outline.md"'
expect_result "T5 quoted paths with spaces — extracts last positional" \
  "$CMD_T5" '"/a/path with space/outline.md"'

# ── T6: multi-line command with ; prefix ─────────────────────────────────────
CMD_T6='cd /tmp; assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md /tmp/test-outline.md'
expect_result "T6 ; prefix — returns 3rd positional after assemble invocation" \
  "$CMD_T6" '"/tmp/test-outline.md"'

# ── T7: malformed (no positionals after script) ──────────────────────────────
CMD_T7='assemble-mandatory.sh --source-kind intent'
expect_result "T7 no positionals after script — returns null" \
  "$CMD_T7" 'null'

# ── T8: chained after && echo ok ─────────────────────────────────────────────
CMD_T8='assemble-mandatory.sh --source-kind intent /a/intent.md /a/draft.md /tmp/test-outline.md && echo ok'
expect_result "T8 trailing && echo — returns 3rd positional, ignores trailing" \
  "$CMD_T8" '"/tmp/test-outline.md"'

# ── T9: multi-line backslash-LF continuation (POSIX) ─────────────────────────
# Mirrors the actual SKILL.md form: backslash followed by newline.
# NODE_TMPDIR gives a Windows-style path on Windows so MSYS2 path conversion
# in env vars does not corrupt the \<LF> continuation bytes.
CMD_T9=$(printf '"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \\\n  "%s/20260527-intent.md" \\\n  "%s/20260527-outline.md" \\\n  "%s/20260527-outline.md"' "$NODE_TMPDIR" "$NODE_TMPDIR" "$NODE_TMPDIR")
expect_result "T9 multi-line \\<LF> continuation — returns last path" \
  "$CMD_T9" "\"${NODE_TMPDIR}/20260527-outline.md\""

# ── T10: multi-line backslash-CRLF continuation (Windows) ────────────────────
CMD_T10=$(printf '"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent \\\r\n  "%s/20260527-intent.md" \\\r\n  "%s/20260527-outline.md" \\\r\n  "%s/20260527-outline.md"' "$NODE_TMPDIR" "$NODE_TMPDIR" "$NODE_TMPDIR")
expect_result "T10 multi-line \\<CRLF> continuation — returns last path" \
  "$CMD_T10" "\"${NODE_TMPDIR}/20260527-outline.md\""

# ── T11: wrapper env-var-only form (no positionals) — returns null ────────────
CMD_T11='SESSION_ID=abc PLANS_DIR=/tmp "$AGENTS_CONFIG_DIR/skills/make-outline-plan/scripts/assemble-mandatory.sh"'
expect_result "T11 wrapper env-var-only (no positionals) — returns null (retired pattern)" \
  "$CMD_T11" 'null'

# ── T12: env-var prefix + _shared + positionals — returns 3rd positional ──────
CMD_T12='SESSION_ID=abc PLANS_DIR=/tmp "$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent /a/intent.md /a/draft.md /a/outline.md'
expect_result "T12 env-var prefix + positionals — returns 3rd positional" \
  "$CMD_T12" '"/a/outline.md"'

# ── Results ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "All tests passed!"
else
  echo "$ERRORS test(s) failed"
  exit 1
fi
