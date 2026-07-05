# shellcheck shell=bash
# tests/lib/skip-judgment.sh — shared helper for planting valid skip judgments.
# Sourced (not executed) by test files that need to plant a valid recorded
# skip judgment with its artifact file already present.
#
# Required in-scope symbols (must be set/defined BEFORE first use of plant_valid_skip):
#   SKIP_JUDGMENT_RESOLVER_N  — Windows-native (or POSIX) path to
#                               hooks/lib/workflow-state/skip-signal-resolver.js
#   api_exists                — shell function; returns 0 if recordSkipJudgment
#                               exists in the resolver, non-zero otherwise
#   run_with_timeout          — shell function; wraps a command with a timeout

# plant_valid_skip <plans_dir> <sid> <target> <cond>
#
# Plants a valid skip judgment for <sid>/<target> by:
#   1. Creating (touching) the artifact file FIRST so artifact mtime <= recorded_at.
#      Artifact suffix: target=="detail" → "-outline.md", else "-intent.md".
#   2. Calling recordSkipJudgment via the resolver.
#
# When api_exists returns non-zero (pre-implementation), this is a no-op so
# callers can be guarded-skip-safe.
plant_valid_skip() {
  local plans_dir="$1" sid="$2" target="$3" cond="$4"
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
    r.recordSkipJudgment('$sid', '$target', $cond, 'orchestrator');
  " 2>/dev/null || true
}
