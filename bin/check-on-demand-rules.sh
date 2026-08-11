#!/usr/bin/env bash
# check-on-demand-rules.sh — static gate for the on-demand rules-injection notation.
#
# Why: a rule that must NOT be auto-injected disables injection by declaring the
# reserved `paths:` glob `.on-demand-only/never-match`. Nothing in the host loader
# validates that convention, so the notation can rot silently — a token without its
# marker comment, a marker without its token, a near-miss spelling that matches
# nothing while looking correct. This checker is the fail-CLOSED half of the pair
# (the InstructionsLoaded audit hook is the fail-open observational half).
#
# Usage:
#   check-on-demand-rules.sh --all [<root>]
#   check-on-demand-rules.sh --staged [<staged-path>...]
#
# Both modes run the SAME tree-wide invariants; `--staged` additionally surfaces a
# staged path that does not resolve inside the checked root. Staged paths are DATA:
# they are never expanded, evaluated, or followed.
#
# Exit codes: 0 clean | 1 violations found | 2 usage or unreadable policy.
#
# The policy constants come from the tree UNDER CHECK (`$RULES_INJECTION_POLICY`, or
# `<root>/hooks/lib/rules-injection-policy.js`), never from this repo's own copy, so
# `--all <other-root>` grades that tree against its own declarations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$SCRIPT_DIR/lib/check-on-demand-rules.js"

usage() {
    cat >&2 <<'USAGE'
usage: check-on-demand-rules.sh --all [<root>]
       check-on-demand-rules.sh --staged [<staged-path>...]
USAGE
    exit 2
}

# Node.js on Windows cannot open an MSYS-style path (as emitted by Git Bash `pwd`).
node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

[[ $# -ge 1 ]] || usage

MODE="$1"
shift

case "$MODE" in
    --all)
        [[ $# -le 1 ]] || usage
        ROOT="${1:-$PWD}"
        ;;
    --staged)
        ROOT=""
        if command -v git >/dev/null 2>&1; then
            ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        fi
        [[ -n "$ROOT" ]] || ROOT="$PWD"
        ;;
    *)
        usage
        ;;
esac

[[ -f "$IMPL" ]] || { echo "check-on-demand-rules: missing implementation: $IMPL" >&2; exit 2; }

POLICY="${RULES_INJECTION_POLICY:-$ROOT/hooks/lib/rules-injection-policy.js}"

RC=0
if [[ "$MODE" == "--all" ]]; then
    node "$(node_path "$IMPL")" --all "$(node_path "$ROOT")" "$(node_path "$POLICY")" || RC=$?
else
    node "$(node_path "$IMPL")" --staged "$(node_path "$ROOT")" "$(node_path "$POLICY")" "$@" || RC=$?
fi
exit "$RC"
