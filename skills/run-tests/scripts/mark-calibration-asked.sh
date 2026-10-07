#!/usr/bin/env bash
# mark-calibration-asked.sh --session <sid>
# Records that /run-tests asked the calibration question in this session (RNT-6a), before
# the dialog opens. Its only write is one asked_at= line appended to the session marker.
# Prints first=yes|no (yes: no earlier line existed, so this caller may open the dialog).
# Exit: 0 recorded; 1 the marker could not be written; 2 usage error.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/calibration-offer.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/calibration-offer.sh"
co_parse_args 0 "$@"

if ! co_marker_write "$CO_SID" "asked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
    printf '%s\n' "mark-calibration-asked: cannot write the session marker (invalid session id or unwritable control dir)" >&2
    exit 1
fi
# first=yes only when this call's line is the sole line: two concurrent callers both see 2 and
# both fall back to the notice, so the dialog never opens twice for one session.
marker="$(co_marker_path "$CO_SID")" || marker=""
lines=2
[ -n "$marker" ] && lines="$(wc -l < "$marker" 2>/dev/null | tr -d ' ')"
if [ "${lines:-2}" = "1" ]; then printf 'first=yes\n'; else printf 'first=no\n'; fi
exit 0
