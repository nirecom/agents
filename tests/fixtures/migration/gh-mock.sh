#!/bin/bash
# gh mock for migrate-repo canary tests.
#
# Behavior:
#   gh issue create ...   → log invocation, return sequential issue number (101+).
#   gh project item-add . → exit 0.
#   gh api ...            → exit 0 with minimal JSON.
#   anything else         → exit 0.
#
# Environment:
#   MOCK_LOG       — file to append invocation lines to (required for create logging).
#   MOCK_COUNTER   — file holding the next issue number (auto-initialized to 101).
#
# Exit 99 from this script means an unexpected branch was hit (test failure marker).

set -u

LOG="${MOCK_LOG:-/dev/null}"
COUNTER_FILE="${MOCK_COUNTER:-/tmp/gh-mock-counter}"

# Initialize counter if missing.
if [ ! -f "$COUNTER_FILE" ]; then
    echo 101 > "$COUNTER_FILE"
fi

cmd="${1:-}"
shift || true

case "$cmd" in
    issue)
        sub="${1:-}"; shift || true
        case "$sub" in
            create)
                # Log full args for later inspection.
                echo "gh issue create $*" >> "$LOG"
                n=$(cat "$COUNTER_FILE")
                echo "$((n + 1))" > "$COUNTER_FILE"
                # gh prints the issue URL to stdout on create.
                echo "https://github.com/example/repo/issues/$n"
                exit 0
                ;;
            list)
                # Return one issue when MOCK_HAS_ISSUES=1, else empty list.
                echo "gh issue list $*" >> "$LOG"
                if [ "${MOCK_HAS_ISSUES:-}" = "1" ]; then
                    echo '[{"number":5}]'
                else
                    echo '[]'
                fi
                exit 0
                ;;
            view)
                # Return minimal JSON node id when --json id is requested.
                echo '{"id":"I_kwDOmockNode"}'
                exit 0
                ;;
            *)
                echo "gh issue $sub $*" >> "$LOG"
                exit 0
                ;;
        esac
        ;;
    project)
        sub="${1:-}"; shift || true
        echo "gh project $sub $*" >> "$LOG"
        # Return JSON-ish for create / field-create if needed.
        echo '{"number":99,"id":"PVT_mock","fields":{"nodes":[]}}'
        exit 0
        ;;
    api)
        echo "gh api $*" >> "$LOG"
        echo '{}'
        exit 0
        ;;
    auth)
        # Pretend we are authenticated.
        exit 0
        ;;
    *)
        echo "gh $cmd $*" >> "$LOG"
        exit 0
        ;;
esac
