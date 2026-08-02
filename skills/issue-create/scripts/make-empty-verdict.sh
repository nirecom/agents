#!/usr/bin/env bash
# make-empty-verdict.sh <out-path> <verdict> --title T --background B --changes C [--target N] [--parent N]
#
# Emit a schema-v2 survey artifact for the three routes that never reach the
# survey worker: zero candidates, a non-GitHub remote, and --skip-survey
# (bulk-sub-of). Downstream readers then use one shape on every route.
#
# Deterministic and idempotent: the same arguments produce a byte-identical file
# (no timestamps, no session ids). Written via <out>.tmp + rename, so a partial
# write never becomes a visible artifact and no temp file is left behind.

set -euo pipefail

usage() {
    echo "Error: usage: make-empty-verdict.sh <out-path> <verdict> --title T --background B --changes C [--target N] [--parent N]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage

OUT="$1"
VERDICT="$2"
shift 2

# `bulk-sub-of` is a survey-level verdict, not a review-level one: it exists only on
# the --skip-survey route, and writing it as plain `sub-of` would tell every downstream
# reader that one child was attached when N were.
case "$VERDICT" in
    none|reopen|sub-of|bulk-sub-of|make-parent|sibling) ;;
    *) echo "Error: unknown verdict: $VERDICT" >&2; exit 2 ;;
esac

TITLE=""
BACKGROUND=""
CHANGES=""
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title)      TITLE="${2:?--title requires value}";      shift 2 ;;
        --background) BACKGROUND="${2:?--background requires value}"; shift 2 ;;
        --changes)    CHANGES="${2:?--changes requires value}";   shift 2 ;;
        --target)     TARGET="${2:?--target requires value}";     shift 2 ;;
        --parent)     TARGET="${2:?--parent requires value}";     shift 2 ;;
        -h|--help)    usage ;;
        *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$TITLE" ]] || { echo "Error: --title is required and must be non-empty" >&2; exit 2; }

# GitHub issue numbers start at 1, and a leading zero is not the number it looks like
# once `Number()` gets hold of it. `^[0-9]+$` admitted both `0` and `007`.
if [[ -n "$TARGET" ]] && ! printf '%s' "$TARGET" | grep -qE '^[1-9][0-9]*$'; then
    echo "Error: --target/--parent must be a positive integer, got: $TARGET" >&2
    exit 2
fi

TMP="${OUT}.tmp"
trap 'rm -f "$TMP"' EXIT

# node is a native Windows binary under Git Bash — a POSIX-style path is not
# resolvable there (rules/coding/nodejs.md).
if command -v cygpath >/dev/null 2>&1; then
    TMP_NODE="$(cygpath -m "$(dirname "$TMP")")/$(basename "$TMP")"
else
    TMP_NODE="$TMP"
fi

MEV_TITLE="$TITLE" MEV_BACKGROUND="$BACKGROUND" MEV_CHANGES="$CHANGES" \
MEV_VERDICT="$VERDICT" MEV_TARGET="$TARGET" \
node -e '
"use strict";
const fs = require("fs");
const target = process.env.MEV_TARGET ? Number(process.env.MEV_TARGET) : null;
const artifact = {
  schema_version: 2,
  proposal: {
    title: process.env.MEV_TITLE || "",
    background: process.env.MEV_BACKGROUND || "",
    changes: process.env.MEV_CHANGES || ""
  },
  verdict: process.env.MEV_VERDICT,
  target: target,
  children: [],
  related: [],
  reason: "survey skipped: no candidate set was collected on this route",
  relations_mode: "unavailable",
  relation_errors: [],
  candidates: []
};
fs.writeFileSync(process.argv[1], JSON.stringify(artifact, null, 2) + "\n");
' "$TMP_NODE"

mv -f "$TMP" "$OUT"
trap - EXIT
printf '%s\n' "$OUT"
