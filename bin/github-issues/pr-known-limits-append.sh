#!/usr/bin/env bash
# pr-known-limits-append.sh --branch <b> --file <entry> — add the entry as one `- ` line to the
# `## Known limits` section of the branch's single PR (created at the end when absent) (#2019).
# A line already in the section is not added again (a retried pass stays one line).
# The added line passes gh_outbound_guard and gh_user_block_guard before `gh pr edit`.
# Exit: 0 added or already present; 2 bad arguments; 1 PR count != 1, a guard stop, gh failure.

set -euo pipefail

BRANCH=""
ENTRY_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="${2:-}"; shift 2 || shift ;;
        --file)   ENTRY_FILE="${2:-}"; shift 2 || shift ;;
        *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$BRANCH" || -z "$ENTRY_FILE" ]]; then
    echo "Error: usage: pr-known-limits-append.sh --branch <b> --file <entry>" >&2
    exit 2
fi
if [[ ! -f "$ENTRY_FILE" ]]; then
    echo "Error: entry file not found: ${ENTRY_FILE}" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

# shellcheck source=../lib/gh-outbound-guard.sh
. "$(dirname "$0")/../lib/gh-outbound-guard.sh"
# shellcheck source=../lib/native-path.sh
. "$(dirname "$0")/../lib/native-path.sh"
# shellcheck source=../lib/gh-user-block-guard.sh
. "$(dirname "$0")/../lib/gh-user-block-guard.sh"

LINE_FILE="$(mktemp)"
BODY_FILE="$(mktemp)"
NEW_BODY_FILE="$(mktemp)"
chmod 600 "$LINE_FILE" "$BODY_FILE" "$NEW_BODY_FILE"
trap 'rm -f "$LINE_FILE" "$BODY_FILE" "$NEW_BODY_FILE"' EXIT

# The entry's first non-blank line, whitespace collapsed, as one `- ` bullet.
ENTRY="$(grep -m 1 -v '^[[:space:]]*$' "$ENTRY_FILE" | tr -d '\r' | tr -s ' \t' ' ' | sed -e 's/^ *//' -e 's/ *$//' -e 's/^- //' || true)"
if [[ -z "$ENTRY" ]]; then
    echo "Error: entry file has no text: ${ENTRY_FILE}" >&2
    exit 2
fi
printf -- '- %s\n' "$ENTRY" > "$LINE_FILE"

gh_outbound_guard "pr-known-limits:${BRANCH}" < "$LINE_FILE" || exit 1
gh_user_block_guard "pr-known-limits:${BRANCH}" --op create --new-body-file "$(native_path "$LINE_FILE")" || exit 1

PR_NUMBERS="$(MSYS_NO_PATHCONV=1 gh pr list --head "$BRANCH" --state all --json number --jq '.[].number' | tr -d '\r' | grep -E '^[0-9]+$' || true)"
PR_COUNT="$(printf '%s' "$PR_NUMBERS" | grep -c . || true)"
if [[ "$PR_COUNT" -ne 1 ]]; then
    echo "Error: expected exactly 1 PR for ${BRANCH}, found ${PR_COUNT}" >&2
    exit 1
fi
PR="$PR_NUMBERS"

if ! MSYS_NO_PATHCONV=1 gh pr view "$PR" --json body --jq .body > "$BODY_FILE"; then
    echo "Error: gh pr view ${PR} failed" >&2
    exit 1
fi

# rc 0 = composed into NEW_BODY_FILE; rc 3 = the line is already in the section.
COMPOSE_RC=0
node -e '
const fs = require("fs");
const [bodyPath, linePath, outPath] = process.argv.slice(1);
const line = fs.readFileSync(linePath, "utf8").replace(/\r?\n$/, "");
const lines = fs.readFileSync(bodyPath, "utf8").replace(/\r\n/g, "\n").replace(/\n+$/, "").split("\n");
const head = lines.findIndex((l) => /^## Known limits\s*$/.test(l));
if (head === -1) {
  while (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop();
  if (lines.length > 0) lines.push("");
  lines.push("## Known limits", line);
} else {
  let end = lines.findIndex((l, i) => i > head && /^## /.test(l));
  if (end === -1) end = lines.length;
  if (lines.slice(head + 1, end).some((l) => l.trimEnd() === line)) process.exit(3);
  let at = end;
  while (at > head + 1 && lines[at - 1].trim() === "") at -= 1;
  lines.splice(at, 0, line);
}
fs.writeFileSync(outPath, lines.join("\n") + "\n");
' "$(native_path "$BODY_FILE")" "$(native_path "$LINE_FILE")" "$(native_path "$NEW_BODY_FILE")" || COMPOSE_RC=$?
if [[ "$COMPOSE_RC" -eq 3 ]]; then
    echo "pr-known-limits: already present in #${PR}"
    exit 0
elif [[ "$COMPOSE_RC" -ne 0 ]]; then
    echo "Error: could not compose the PR body (rc=${COMPOSE_RC})" >&2
    exit 1
fi

if ! MSYS_NO_PATHCONV=1 gh pr edit "$PR" --body-file "$(native_path "$NEW_BODY_FILE")" >/dev/null; then
    echo "Error: gh pr edit ${PR} failed" >&2
    exit 1
fi
echo "pr-known-limits: added to #${PR}"
