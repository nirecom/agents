#!/usr/bin/env bash
# Create a task issue with the enforced type:task label and attach to Projects v2.
# Scope: task issues for the current repo only.
# Incidents and cross-project issues: use gh issue create directly.
#
# Usage:
#   issue-create.sh --title "<title>" (--body "<body>" | --body-file <path>)
#                   [--label <label>] [--assignee <user>] [--milestone <name>]
#
# Stdout: created issue URL (one line).
# Stderr: progress and warnings.

# -e is safe here: all gh invocations use `if !` blocks, which are exempt from errexit.
set -euo pipefail

OWNER="${ISSUE_CREATE_OWNER:-nirecom}"
PROJECT_NUM="${ISSUE_CREATE_PROJECT_NUM:-1}"

TITLE=""
BODY=""
BODY_FILE=""
EXTRA_LABELS=()
ASSIGNEE=""
MILESTONE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --title)      TITLE="${2:?--title requires value}"; shift 2 ;;
        --body)       BODY="${2:?--body requires value}"; shift 2 ;;
        --body-file)  BODY_FILE="${2:?--body-file requires value}"; shift 2 ;;
        --label)
            val="${2:?--label requires value}"
            val_lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
            case "$val_lower" in
                type:*)
                    echo "Error: --label $val is not allowed; this skill enforces type:task." >&2
                    echo "For incident issues use: gh issue create --label \"type:incident\" directly." >&2
                    exit 2 ;;
            esac
            EXTRA_LABELS+=("$val"); shift 2 ;;
        --assignee)   ASSIGNEE="${2:?--assignee requires value}"; shift 2 ;;
        --milestone)  MILESTONE="${2:?--milestone requires value}"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" >&2; exit 0 ;;
        *)
            echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2; exit 1
fi

if [ -z "$TITLE" ]; then
    echo "Error: --title required" >&2; exit 2
fi
if [ -z "$BODY" ] && [ -z "$BODY_FILE" ]; then
    echo "Error: --body or --body-file required" >&2; exit 2
fi
if [ -n "$BODY" ] && [ -n "$BODY_FILE" ]; then
    echo "Error: --body and --body-file are mutually exclusive" >&2; exit 2
fi
if [ -n "$BODY_FILE" ] && [ ! -f "$BODY_FILE" ]; then
    echo "Error: --body-file not found: $BODY_FILE" >&2; exit 1
fi

GH_ARGS=(issue create --title "$TITLE" --label "type:task")
if [ -n "$BODY" ]; then
    GH_ARGS+=(--body "$BODY")
else
    GH_ARGS+=(--body-file "$BODY_FILE")
fi
for L in "${EXTRA_LABELS[@]:-}"; do
    [ -z "$L" ] && continue
    GH_ARGS+=(--label "$L")
done
[ -n "$ASSIGNEE" ]  && GH_ARGS+=(--assignee  "$ASSIGNEE")
[ -n "$MILESTONE" ] && GH_ARGS+=(--milestone "$MILESTONE")

echo "[issue-create] gh issue create --title '$TITLE' [body omitted]" >&2
if ! URL=$(gh "${GH_ARGS[@]}"); then
    echo "Error: gh issue create failed" >&2; exit 1
fi
if [ -z "$URL" ]; then
    echo "Error: gh issue create returned no URL" >&2; exit 1
fi

# Normalize: gh prints the URL on the last line; strip Windows CR if present.
URL=$(printf '%s' "$URL" | tail -n 1 | tr -d '\r')
if ! printf '%s' "$URL" | grep -qE '^https://github\.com/.+/issues/[0-9]+$'; then
    echo "Error: unexpected output from gh issue create: $URL" >&2
    exit 1
fi

echo "[issue-create] attaching to Projects v2 (project #$PROJECT_NUM, owner $OWNER): $URL" >&2
if ! gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$URL" >/dev/null 2>&1; then
    echo "warn: failed to attach $URL to project $PROJECT_NUM (continuing)" >&2
fi

printf '%s\n' "$URL"
