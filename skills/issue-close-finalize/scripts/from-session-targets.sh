#!/bin/bash
# from-session-targets.sh — the `--from-session` target set (#3043).
#
# Usage: from-session-targets.sh --session <sid> --owner-repo <owner/repo>
# Output (stdout):
#   TARGET <ref>      — one per CLOSED issue; run the finalize pipeline for these only.
#   GUIDANCE <ref> …  — one per OPEN or unknown issue; relay verbatim, write no entry.
# With no TARGET line, the empty outcome bag is written, unless it already holds recorded entries (kept).
# Exit codes: 0 on success; 1 on a usage error, an unreadable intent, or a failed state lookup.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
USAGE="Usage: from-session-targets.sh --session <sid> --owner-repo <owner/repo>"

session_id=""
owner_repo=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session) session_id="${2:-}"; shift 2 || { echo "$USAGE" >&2; exit 1; } ;;
        --owner-repo) owner_repo="${2:-}"; shift 2 || { echo "$USAGE" >&2; exit 1; } ;;
        *) echo "$USAGE" >&2; exit 1 ;;
    esac
done
[[ -n "$session_id" ]] || { echo "$USAGE" >&2; exit 1; }

targets_json="$(node "$SCRIPT_CHECKOUT_ROOT/bin/issue-close-session-targets.js" --session "$session_id" --owner-repo "$owner_repo")"

# shellcheck disable=SC2016
lines="$(node -e '
const t = JSON.parse(process.argv[1]);
const out = [];
for (const ref of t.closed) out.push(`TARGET ${ref}`);
for (const ref of t.open) out.push(`GUIDANCE ${ref} is still OPEN; close it on its own with /issue-close-finalize ${ref}`);
for (const ref of t.unknown) out.push(`GUIDANCE ${ref} state is unknown; check it and run /issue-close-finalize ${ref} on its own`);
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
' "$targets_json")"

[[ -z "$lines" ]] || printf '%s\n' "$lines"

if ! grep -q '^TARGET ' <<<"$lines"; then
    node "$SCRIPT_CHECKOUT_ROOT/bin/issue-close-write-outcome.js" --session "$session_id" --empty >/dev/null
    echo "NO_TARGETS: outcome bag settled (empty, or its recorded entries kept)"
fi
