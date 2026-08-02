#!/usr/bin/env bash
# severity-audit.sh — enumerate the current `severity:high` population (#1763 S15).
#
# WHAT THIS IS NOT: a classifier. The keyword scan that used to infer severity was
# removed precisely because a machine cannot tell "primary feature unusable" from a
# body that merely contains the word "crash". The three conditions in
# skills/issue-create/SKILL.md's label policy are the SSOT, and they are applied by a
# human plus Claude reading each issue — not here.
#
# WHAT THIS IS: a repeatable enumerator. It answers "which issues currently carry the
# label, and when were they filed", so over-classification can be quantified and
# re-checked after a cleanup pass instead of being estimated once and forgotten.
#
# Usage: severity-audit.sh [--label LABEL] [--state open|closed|all] [--limit N]
# Stdout: a TSV header, one row per issue (number / state / createdAt / title), then a
#         blank line and a count summary. Nothing else — the output is meant to be
#         pasted into WORKTREE_NOTES.md or piped to sort/awk.

set -euo pipefail

LABEL="severity:high"
STATE="all"
LIMIT="200"

usage() {
    sed -n '2,18p' "$0" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="${2:?--label requires value}"; shift 2 ;;
        --state) STATE="${2:?--state requires value}"; shift 2 ;;
        --limit) LIMIT="${2:?--limit requires value}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: unknown argument: $1" >&2; usage ;;
    esac
done

case "$STATE" in
    open|closed|all) ;;
    *) echo "Error: --state must be open, closed or all (got: $STATE)" >&2; exit 2 ;;
esac

# The label is handed to `gh` as its own argv element, so the exposure is not shell
# injection but ARGUMENT injection: a value that begins with `-` is read by gh as a
# further flag, and one containing a newline splits the enumeration silently. Constrain
# it to the characters a GitHub label is actually made of, first character alphanumeric.
if [[ ! "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9:._/\ -]{0,48}$ ]]; then
    echo "Error: --label must be 1-49 chars of [A-Za-z0-9:._/ -] starting alphanumeric (got: ${LABEL})" >&2
    exit 2
fi

if [[ ! "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --limit must be a positive integer (got: $LIMIT)" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

RAW=""
if ! RAW="$(MSYS_NO_PATHCONV=1 gh issue list \
        --label "$LABEL" --state "$STATE" --limit "$LIMIT" \
        --json number,title,state,createdAt 2>/dev/null)"; then
    echo "Error: gh issue list failed for label '${LABEL}'" >&2
    exit 1
fi

# Formatting is done in node rather than jq: jq is not a dependency of this repo, and
# the title is free text that must be flattened before it can share a line with tabs.
printf '%s' "$RAW" | node -e '
"use strict";
let d = "";
process.stdin.on("data", (c) => { d += c; });
process.stdin.on("end", () => {
  let rows = [];
  try { rows = JSON.parse(d); } catch (_e) { rows = []; }
  if (!Array.isArray(rows)) rows = [];
  const flat = (v) => String(v == null ? "" : v).replace(/[\t\r\n]+/g, " ").trim();
  process.stdout.write("number\tstate\tcreatedAt\ttitle\n");
  const counts = { OPEN: 0, CLOSED: 0 };
  for (const r of rows) {
    const state = flat(r.state).toUpperCase();
    counts[state] = (counts[state] || 0) + 1;
    process.stdout.write([r.number, state, flat(r.createdAt), flat(r.title)].join("\t") + "\n");
  }
  process.stdout.write("\n");
  process.stdout.write("total: " + rows.length + "\n");
  for (const k of Object.keys(counts)) process.stdout.write(k.toLowerCase() + ": " + counts[k] + "\n");
});
'
