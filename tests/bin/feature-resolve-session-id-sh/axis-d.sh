# Tests: bin/resolve-session-id, hooks/workflow-state/session-id.js
# Tags: scope:common, session-id
# axis-d.sh — Axis D: (retired)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.
#
# B-26/B-27/B-28 exercised CLAUDE_PROJECT_DIR path-encoding variants feeding
# the P7 JSONL-mtime-scan tier. #2270 removed the P7 tier entirely — the
# resolver is now a 4-tier SUPPLY-only chain with no filesystem inference —
# so none of these cases' premises still exist. Deleted rather than rewritten.
