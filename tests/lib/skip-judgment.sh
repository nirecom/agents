# shellcheck shell=bash
# tests/lib/skip-judgment.sh — sourced helper that plants a valid recorded skip judgment.
# Caller must define SKIP_JUDGMENT_RESOLVER_N (resolver path), api_exists and run_with_timeout.

# plant_valid_skip <plans_dir> <sid> <target> <cond> [source]
# Touches the artifact first (detail → -outline.md, else -intent.md) so its mtime
# <= recorded_at, then records <cond>. [source] defaults to "subagent" (a member of
# JUDGMENT_SOURCES since #2460); pass another value only to plant an invalid record.
# No-op when api_exists fails, so callers stay guarded-skip-safe.
plant_valid_skip() {
  local plans_dir="$1" sid="$2" target="$3" cond="$4" source="${5:-subagent}"
  api_exists || return 0
  local suffix
  if [ "$target" = "detail" ]; then
    suffix="-outline.md"
  else
    suffix="-intent.md"
  fi
  : > "${plans_dir}/${sid}${suffix}"
  run_with_timeout node -e "
    const r = require('$SKIP_JUDGMENT_RESOLVER_N');
    r.recordSkipJudgment('$sid', '$target', $cond, '$source');
  " 2>/dev/null || true
}
