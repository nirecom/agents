# Tests: bin/resolve-session-id, hooks/workflow-state/session-id.js
# Tags: scope:common, session-id
# security.sh — Security / charset validation (retired)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.
#
# B-30 defended the removed P7 JSONL-mtime-scan tier against unsafe basenames
# (#2270 dropped P7; the bridge now rc=2s regardless of transcript-dir
# contents, so the case would only restate B-23). P4 basename charset
# rejection lives on in section-supply-tier.sh (JS-23, JS-26) and
# harden-1319-session-id-central-validation.sh (U5). Deleted, not rewritten.
