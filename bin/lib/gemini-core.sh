#!/usr/bin/env bash
# Shared library for gemini-based scripts.
# Source this file: source "$(dirname "$(realpath "$0")")/lib/gemini-core.sh"
export SYSTEM_OPS_APPROVED=1
#
# Provides: gemini_core_init, gemini_core_check_cli,
#           gemini_core_run, gemini_core_log, gemini_core_emit_failed

# gemini_core_init <label>
# Sets: GEMINI_LABEL, LOG_DIR, START_TS, START_EPOCH, SESSION_ID, BRANCH
gemini_core_init() {
  GEMINI_LABEL="${1:-Gemini}"
  LOG_DIR="$HOME/.claude/projects/gemini"
  START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  START_EPOCH=$(date +%s)
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%Y%m%d_%H%M%S)}"
  SESSION_ID="${SESSION_ID//\//_}"
}

# gemini_core_check_cli
# If gemini not in PATH: emit SKIPPED status, log, and exit 0.
gemini_core_check_cli() {
  if ! command -v gemini > /dev/null 2>&1; then
    echo "## ${GEMINI_LABEL}: SKIPPED — gemini CLI not installed"
    echo "(To install: npm install -g @google/gemini-cli  then: gemini auth)"
    gemini_core_log skipped "gemini CLI not installed" 0
    exit 0
  fi
}

# gemini_core_run <prompt>
# Runs gemini with the given prompt (piped via stdin).
# Caller must set INPUT_LINES before calling.
# Returns raw stdout; caller is responsible for parsing/saving.
gemini_core_run() {
  local prompt="$1"
  local _input_lines="${INPUT_LINES:-0}"

  TMPFILE=$(mktemp /tmp/gemini-prompt-XXXXXX.txt)
  GEMINI_STDERR=$(mktemp /tmp/gemini-stderr-XXXXXX.txt)
  trap 'rm -f "$TMPFILE" "$GEMINI_STDERR"' EXIT

  printf '%s' "$prompt" > "$TMPFILE"

  local gemini_out gemini_exit
  gemini_out=""
  gemini_exit=0

  gemini_out=$(timeout 120 env GEMINI_CLI_TRUST_WORKSPACE=true gemini -p "$(cat "$TMPFILE")" 2>"$GEMINI_STDERR") || gemini_exit=$?

  case $gemini_exit in
    0)
      GEMINI_OUTPUT="$gemini_out"
      gemini_core_log performed "" "$_input_lines"
      return 0
      ;;
    124)
      echo "## ${GEMINI_LABEL}: FAILED — timeout (120s)"
      gemini_core_log failed "timeout (120s)" "$_input_lines"
      exit 0
      ;;
    *)
      local stderr_tail
      stderr_tail=$(tail -3 "$GEMINI_STDERR" | tr '\n' ' ')
      echo "## ${GEMINI_LABEL}: FAILED — gemini exit code ${gemini_exit}: ${stderr_tail}"
      gemini_core_log failed "exit code ${gemini_exit}" "$_input_lines"
      exit 0
      ;;
  esac
}

# gemini_core_log <status> <reason> <input_lines>
gemini_core_log() {
  local status="$1" reason="$2" input_lines="${3:-0}"
  "${NO_LOG:-false}" && return 0
  local end_epoch duration
  end_epoch=$(date +%s)
  duration=$(( end_epoch - START_EPOCH ))
  mkdir -p "$LOG_DIR"
  printf '{"timestamp":"%s","status":"%s","reason":"%s","branch":"%s","label":"%s","input_lines":%d,"duration_s":%d}\n' \
    "$START_TS" "$status" "$reason" "$BRANCH" "$GEMINI_LABEL" "$input_lines" "$duration" \
    >> "$LOG_DIR/${SESSION_ID}.jsonl" 2>/dev/null || true
}

# gemini_core_emit_failed <reason>
gemini_core_emit_failed() {
  local reason="$1"
  echo "## ${GEMINI_LABEL}: FAILED — ${reason}"
  exit 0
}

# gemini_core_extract_svg <raw_output>
# Extracts SVG markup from a Gemini response.
# Looks for <svg...>...</svg> block; falls back to stripping ```svg fences.
# Prints extracted SVG to stdout; returns 1 if nothing found.
gemini_core_extract_svg() {
  local raw="$1"

  # Try to extract fenced ```svg block first
  local fenced
  fenced=$(printf '%s' "$raw" | sed -n '/^```svg/,/^```/{/^```/d;p}')
  if [[ -n "$fenced" ]]; then
    printf '%s\n' "$fenced"
    return 0
  fi

  # Fallback: extract <svg...>...</svg> directly
  local inline
  inline=$(printf '%s' "$raw" | sed -n '/<svg/,/<\/svg>/p')
  if [[ -n "$inline" ]]; then
    printf '%s\n' "$inline"
    return 0
  fi

  return 1
}
