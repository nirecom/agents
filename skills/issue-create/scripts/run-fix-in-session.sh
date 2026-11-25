#!/bin/bash
# run-fix-in-session.sh — hand a fix-in-session verdict back to the session as a this-pr finding.
# Usage: bash run-fix-in-session.sh <final-artifact> <notes_path|auto> --closes <N,M,...> --title <T>
#          [--severity <S>] [--finding-key <K>]
# The verdict holds only when its target is a closes_session candidate AND is one of --closes;
# otherwise nothing is written. With --finding-key the rescoped entry returns to this-pr
# (unrescope); without it one RelatedTasks entry "<T> (goal of #<target>)" is appended as this-pr.
# Exit: 0 written (or already present), 1 write failed, 2 verdict refused or bad arguments.
set -euo pipefail

ARTIFACT="${1:-}"
NOTES_PATH="${2:-}"
if [[ -z "$ARTIFACT" || -z "$NOTES_PATH" ]]; then
    echo "run-fix-in-session.sh: usage: <final-artifact> <notes_path|auto> --closes <N,...> --title <T> [--severity <S>] [--finding-key <K>]" >&2
    exit 2
fi
shift 2
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

CLOSES=""
TITLE=""
SEVERITY="medium"
FINDING_KEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --closes) CLOSES="${2-}"; shift 2 ;;
        --title) TITLE="${2:?--title requires a value}"; shift 2 ;;
        --severity) SEVERITY="${2:?--severity requires a value}"; shift 2 ;;
        --finding-key) FINDING_KEY="${2:?--finding-key requires a value}"; shift 2 ;;
        *) echo "run-fix-in-session.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$CLOSES" ]]; then
    echo "run-fix-in-session.sh: refused: the session closes no issue (--closes is empty)" >&2
    exit 2
fi
if [[ -z "$FINDING_KEY" && -z "$TITLE" ]]; then
    echo "run-fix-in-session.sh: --title is required without --finding-key" >&2
    exit 2
fi

TARGET="$(node -e '
const fs = require("fs");
let a;
try { a = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {
  process.stderr.write("cannot read the final artifact: " + e.message + "\n"); process.exit(2);
}
let target = null;
if (a.verdict === "fix-in-session") target = a.target;
else if (a.review && a.review.verdict === "fix-in-session") target = a.review.target;
if (!Number.isInteger(target)) { process.stderr.write("the artifact carries no fix-in-session target\n"); process.exit(2); }
const c = (a.candidates || []).find((x) => x && x.number === target);
if (!c || c.closes_session !== true) {
  process.stderr.write("target #" + target + " is not a closes_session candidate\n"); process.exit(2);
}
const closes = process.argv[2].split(",").map((s) => s.trim().replace(/^#/, ""));
if (!closes.includes(String(target))) {
  process.stderr.write("target #" + target + " is not among the issues this session closes (" + process.argv[2] + ")\n"); process.exit(2);
}
process.stdout.write(String(target));
' "$ARTIFACT" "$CLOSES" 2>&1)" || {
    echo "run-fix-in-session.sh: refused: $TARGET" >&2
    exit 2
}

if [[ "$NOTES_PATH" == "auto" ]]; then
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$TOPLEVEL" ]]; then
        echo "run-fix-in-session.sh: cannot resolve the git toplevel for the notes" >&2
        exit 1
    fi
    NOTES_PATH="$TOPLEVEL/WORKTREE_NOTES.md"
fi

if [[ -n "$FINDING_KEY" ]]; then
    if ! node "$SCRIPT_CHECKOUT_ROOT/bin/worktree-notes-triage.js" unrescope "$NOTES_PATH" "key=$FINDING_KEY"; then
        echo "run-fix-in-session.sh: unrescope failed for key=$FINDING_KEY in $NOTES_PATH" >&2
        exit 1
    fi
    echo "fix-in-session: key=$FINDING_KEY returned to this-pr (goal of #$TARGET) in $NOTES_PATH"
    exit 0
fi

if ! node "$SCRIPT_CHECKOUT_ROOT/bin/worktree-notes-append.js" \
    --notes-path "$NOTES_PATH" \
    --section RelatedTasks \
    --title "$TITLE (goal of #$TARGET)" \
    --severity "$SEVERITY" \
    --pr-scope this-pr; then
    echo "run-fix-in-session.sh: could not record the this-pr entry in $NOTES_PATH" >&2
    exit 1
fi
echo "fix-in-session: recorded \"$TITLE (goal of #$TARGET)\" as this-pr in $NOTES_PATH"
exit 0
