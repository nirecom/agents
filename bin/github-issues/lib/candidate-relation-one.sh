#!/usr/bin/env bash
# candidate-relation-one.sh <owner/repo> <N>
#
# Fallback for bin/github-issues/candidate-relations.sh: resolve ONE candidate's
# relation via GraphQL when the batched aliased query returned `errors` for it.
#
# Same GraphQL shape as lib/parent-number.sh's github_parent_number (the parent
# link is unreachable via REST — see that file), extended with the parent's
# labels so `parent_is_meta` can be derived, and with subIssues.totalCount so
# `has_sub_issues` can be derived. parent-all-closed-check.sh is deliberately
# NOT used here: it answers "are the children closed", never "who is the parent".
#
# Stdout: the raw GraphQL response (shape: .data.repository.issue).
# Exit:   0 when gh succeeded, non-zero otherwise. The caller normalizes.

set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "Error: usage: candidate-relation-one.sh <owner/repo> <N>" >&2
    exit 2
fi

REPO="$1"
N="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 2
fi
if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $N" >&2
    exit 2
fi

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# 100 is the GraphQL page maximum, and the page is what decides `parent_is_meta`:
# a `meta` label sitting past the end of the page reads exactly like no meta label,
# which silently drops the parent out of the sub-of rule. Kept identical to the
# batched query in candidate-relations.sh (CPR-5) — the two must not diverge.
QUERY="{ repository(owner: \"${OWNER}\", name: \"${NAME}\") { issue(number: ${N}) { number state parent { number state labels(first: 100) { nodes { name } } } subIssues(first: 1) { totalCount } } } }"

gh api graphql -f query="$QUERY" 2>/dev/null | tr -d '\r'
exit "${PIPESTATUS[0]}"
