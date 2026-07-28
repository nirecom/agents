#!/usr/bin/env bash
# issue-body-append.sh — append an intent-revision note to an existing issue body (#1591)
#
# Usage:
#   issue-body-append.sh --issue <N> [--repo <slug>] (--note <text> | --note-file <path>)
#
# Appends a `### Revision (<UTC ISO8601>)` entry inside a SINGLE
# <!-- BEGIN intent-revisions --> ... <!-- END intent-revisions --> region
# (created at the end of the body when absent). Prior revision entries and all
# body content outside the region are preserved verbatim. The composed body is
# scanned by gh_outbound_guard before `gh issue edit`.
#
# Exit: 0 success, 1 gh failure or scan block, 2 usage error.
set -euo pipefail

ISSUE_NUMBER=""
REPO_SLUG=""
NOTE=""
NOTE_FILE=""
NOTE_PROVIDED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)     ISSUE_NUMBER="${2:-}"; shift 2 ;;
        --repo)      REPO_SLUG="${2:-}"; shift 2 ;;
        --note)      NOTE="${2:-}"; NOTE_PROVIDED=1; shift 2 ;;
        --note-file) NOTE_FILE="${2:-}"; shift 2 ;;
        -h|--help)   sed -n '2,10p' "$0" >&2; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! printf '%s' "$ISSUE_NUMBER" | grep -qE '^[0-9]+$'; then
    echo "Error: --issue must be digits only (got: ${ISSUE_NUMBER})" >&2
    exit 2
fi
if [[ "$NOTE_PROVIDED" -eq 1 && -n "$NOTE_FILE" ]]; then
    echo "Error: --note and --note-file are mutually exclusive" >&2
    exit 2
fi
if [[ "$NOTE_PROVIDED" -eq 0 && -z "$NOTE_FILE" ]]; then
    echo "Error: exactly one of --note or --note-file is required" >&2
    exit 2
fi
if [[ -n "$NOTE_FILE" ]]; then
    if [[ ! -f "$NOTE_FILE" ]]; then
        echo "Error: --note-file not found: $NOTE_FILE" >&2
        exit 2
    fi
    NOTE="$(cat "$NOTE_FILE")"
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

REPO_ARGS=()
[[ -n "$REPO_SLUG" ]] && REPO_ARGS+=(--repo "$REPO_SLUG")

BODY_TMPFILE="$(mktemp)"
chmod 600 "$BODY_TMPFILE"
trap 'rm -f "$BODY_TMPFILE"' EXIT

CUR=""
CUR="$(MSYS_NO_PATHCONV=1 gh issue view "$ISSUE_NUMBER" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json body --jq .body)" || {
    echo "Error: gh issue view ${ISSUE_NUMBER} failed" >&2
    exit 1
}

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || TS="unknown"
ENTRY="### Revision (${TS})

${NOTE}"

if printf '%s\n' "$CUR" | grep -q '<!-- END intent-revisions -->'; then
    # Append inside the existing region, immediately before its END marker.
    printf '%s\n' "$CUR" | ENTRY="$ENTRY" awk '
        /<!-- END intent-revisions -->/ && !inserted { print ENVIRON["ENTRY"]; print ""; inserted = 1 }
        { print }
    ' > "$BODY_TMPFILE"
else
    {
        printf '%s\n' "$CUR"
        printf '\n<!-- BEGIN intent-revisions -->\n\n%s\n\n<!-- END intent-revisions -->\n' "$ENTRY"
    } > "$BODY_TMPFILE"
fi

# shellcheck source=../lib/gh-outbound-guard.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/gh-outbound-guard.sh"
gh_outbound_guard "issue-body-append:#$ISSUE_NUMBER" < "$BODY_TMPFILE" || exit 1

if ! MSYS_NO_PATHCONV=1 gh issue edit "$ISSUE_NUMBER" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --body-file "$BODY_TMPFILE" >/dev/null; then
    echo "Error: gh issue edit ${ISSUE_NUMBER} failed" >&2
    exit 1
fi
