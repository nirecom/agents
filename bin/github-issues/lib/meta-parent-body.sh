#!/usr/bin/env bash
# meta-parent-body.sh — generate the body of a meta parent created by `make-parent`.
#
# Usage:
#   meta-parent-body.sh --title "<group theme>" [--children "N,M,..."]
#
# Stdout: the parent issue body. Stderr: nothing on success.
#
# The parent is a container, not work. The proposal that triggered `make-parent` is
# filed unmodified as a CHILD, so this body must never restate it — it says what the
# group is and, explicitly, that nothing is implemented against the parent itself.
# `Background` / `Changes` are the canonical fields issue-create.sh validates, so the
# generated body has to carry them like any hand-written one.

set -uo pipefail

TITLE=""
CHILDREN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --title)
            [ $# -ge 2 ] || { echo "Error: --title requires a value" >&2; exit 2; }
            TITLE="$2"; shift 2 ;;
        --children)
            [ $# -ge 2 ] || { echo "Error: --children requires a value" >&2; exit 2; }
            CHILDREN="$2"; shift 2 ;;
        *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$TITLE" ]; then
    echo "Error: --title is required" >&2; exit 2
fi

REFS=""
if [ -n "$CHILDREN" ]; then
    IFS=',' read -ra _C <<< "$CHILDREN"
    for c in "${_C[@]:-}"; do
        c="${c// /}"
        [ -z "$c" ] && continue
        [ -n "$REFS" ] && REFS="$REFS, "
        REFS="${REFS}#${c}"
    done
fi

# The FIRST line is deliberately self-describing: it names the theme, says the parent
# carries no implementation, and points at the sub-issues. Anything that reads only the
# opening line of an issue body (previews, notification digests, argv logs) still gets
# the one fact that matters — do not implement against this issue.
printf 'Background: These issues share one theme — %s. Each still needs its own fix, so they are grouped rather than merged; this parent carries no implementation of its own, and the Changes live in its sub-issues.\n' "$TITLE"
printf 'Changes: Nothing is implemented here. Close this issue only once every sub-issue below is closed.\n'
if [ -n "$REFS" ]; then
    printf '\nGrouped at creation: %s\n' "$REFS"
fi
