# Tests: bin/resolve-session-id, hooks/workflow-state/session-id.js
# Tags: scope:common, session-id
# axis-b.sh — Axis B: (retired)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.
#
# B-22 tested the isSameGitRepo security gate around the P7 JSONL-mtime-scan
# tier. #2270 removed both the P7 tier and its isSameGitRepo guard — the
# resolver is now a 4-tier SUPPLY-only chain with no filesystem inference — so
# the case's premise no longer exists. Deleted rather than rewritten.
