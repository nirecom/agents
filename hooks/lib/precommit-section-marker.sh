#!/bin/bash
# Sourced by hooks/pre-commit and hooks/lib/precommit-agents-repo-gates.sh.
# _precommit_section <name> prints one `pre-commit-section: <name>` line on stderr at the
# start of a section, so a caller that stops a slow commit can name where it stopped.
# Format contract (<name> is [a-z0-9][a-z0-9-]*, only the last line counts):
# docs/architecture/claude-code/worker-dispatch/commit-push.md
# "The commit timeout limit and the pre-commit section marker"

_precommit_section() {
    # A closed stderr must not stop the hook under set -e: the marker is diagnostic only.
    printf 'pre-commit-section: %s\n' "$1" >&2 2>/dev/null || :
}
