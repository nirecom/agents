#!/usr/bin/env bash
# require-meta-parent.sh — parent-eligibility guard for the sub-issue attach routes.
#
# Usage:
#   require-meta-parent.sh <issue-number>
#
# An issue is an eligible sub-issue parent only when BOTH hold:
#   - it carries the `meta` label, AND
#   - its title begins with `Group: `
# The AND is the point. A bare `meta` label on an issue that was never scoped as a
# group would otherwise be a one-command bypass of the whole model.
#
# The answer is read from the forge at call time, never from the survey artifact:
# the artifact's `parent_is_meta` was computed before the operator saw it, and the
# issue may have been retitled or relabelled since.
#
# Exit:
#   0  eligible
#   2  usage error
#   3  ineligible — the parent exists but fails at least one condition
#   4  indeterminate — the lookup could not be completed (fail CLOSED at the caller)
#
# There is deliberately NO environment bypass. A skip switch would be discovered and
# used, and the failure it prevents (an orphan issue that cannot be un-created) is
# exactly the one nobody notices until cleanup.

set -uo pipefail

NUM="${1:-}"

if [ $# -ne 1 ] || ! [[ "$NUM" =~ ^[0-9]+$ ]]; then
    echo "Usage: require-meta-parent.sh <issue-number>" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "require-meta-parent: gh CLI not found — parent eligibility is indeterminate" >&2
    exit 4
fi

# The `2>&1` below is what makes the failure diagnostic useful — gh writes its real
# error text to stderr — but under `GH_DEBUG=api` that same stream carries the HTTP
# request headers, `Authorization` among them. Relaying $RAW verbatim would put a PAT
# into this script's stderr, into the dispatcher's stderr, and into the stderr.txt
# artifact left on disk. Redact before anything is emitted: a masked diagnostic is
# still a diagnostic, a leaked token is not recoverable.
#
# Two independent layers, deliberately: drop the debug header lines outright, AND mask
# the credential shapes wherever else they appear. Either alone would be one gh output
# format change away from leaking. The tail cap keeps a full `GH_DEBUG` trace from
# burying the one line that explains the failure.
redact_gh_output() {
    sed -e '/^[[:space:]]*[<>][[:space:]]/d' \
        -e 's/[Aa]uthorization:[[:space:]]*[^[:space:]]*/Authorization: [REDACTED]/g' \
        -e 's/gh[pousr]_[A-Za-z0-9]\{20,\}/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]\{20,\}/[REDACTED]/g' \
        -e 's/[Bb]earer[[:space:]][A-Za-z0-9._~+\/-]\{20,\}=*/Bearer [REDACTED]/g' \
        | head -n 40
}

# ONE round trip answers both conditions. Two lookups could observe two different
# states of the same issue, and the second would silently win.
RAW=""
if ! RAW="$(gh issue view "$NUM" --json labels,title \
        --jq '(([.labels[].name] | index("meta")) != null), (.title | startswith("Group: "))' 2>&1)"; then
    echo "require-meta-parent: could not read issue #${NUM} — parent eligibility is indeterminate" >&2
    printf '%s\n' "$RAW" | redact_gh_output >&2
    exit 4
fi

HAS_META="$(printf '%s\n' "$RAW" | sed -n '1p' | tr -d '[:space:]')"
HAS_GROUP="$(printf '%s\n' "$RAW" | sed -n '2p' | tr -d '[:space:]')"

case "${HAS_META}/${HAS_GROUP}" in
    true/true|true/false|false/true|false/false) ;;
    *)
        echo "require-meta-parent: unreadable lookup result for issue #${NUM} — parent eligibility is indeterminate" >&2
        exit 4 ;;
esac

if [ "$HAS_META" = "true" ] && [ "$HAS_GROUP" = "true" ]; then
    exit 0
fi

state() { [ "$1" = "true" ] && printf 'present' || printf 'MISSING'; }

{
    echo "require-meta-parent: issue #${NUM} is not a meta parent — refusing to attach a sub-issue under it."
    echo "    required: the \`meta\` label            → $(state "$HAS_META")"
    echo "    required: a \`Group: \` title prefix     → $(state "$HAS_GROUP")"
    echo "Recovery (see rules/github-issues.md, \"Converting an issue into a meta parent\"):"
    echo "  1) Convert #${NUM} into a real meta parent: retitle it \`Group: <theme>\`, move its own implementation work out into a sub-issue, and only then mark it meta."
    echo "  2) Leave #${NUM} alone and re-run /issue-create, letting the make-parent verdict create a new meta parent for this work."
} >&2

exit 3
