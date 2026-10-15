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

# plant_finalized_ticket <repo_root> <sid> <target> <ticket> <conds-json> [source] [field=json ...]
# Plants the finalized cli-ticket claim record-skip-judgment verifies its --ticket/--cond/
# --source against (#2460). The caller must have exported AGENTS_STATE_DIR to a temp dir and
# must plant AFTER the session's plan artifacts exist (the claim fingerprints them as they are).
# field=json overrides one claim field, to plant a claim the CLI must refuse.
plant_finalized_ticket() {
  local root="$1" sid="$2" target="$3" ticket="$4" conds="$5" source="${6:-subagent}"
  shift 5
  [ "$#" -gt 0 ] && shift
  node "$root/tests/lib/finalized-ticket.js" "$root" "$sid" "$target" "$ticket" "$conds" "$source" "$@" >/dev/null
}
