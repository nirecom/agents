#!/usr/bin/env bash
#
# bin/sweep-issues/list-band.sh — SI-1 band fetcher.
#
# Emits one deterministic slice of the open-issue list as a JSON array on stdout,
# a bounded, resumable unit of work. Issues are sorted by number ASCENDING before
# slicing, so band K is stable for a repository snapshot regardless of gh order.
# --snapshot-out/--snapshot-in and --count support a one-fetch multi-band sweep.
# Read-only: no writes, no close helpers. See usage() for flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO=""
BAND_SIZE=100
BAND_INDEX=0
GH_LIMIT=1000
COUNT_MODE=0
SNAPSHOT_OUT=""
SNAPSHOT_IN=""

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues/list-band.sh --repo OWNER/REPO [--band-size N] [--band-index K]
                                     [--count] [--snapshot-out FILE] [--snapshot-in FILE]

  --repo OWNER/REPO     Repository to list open issues from (required).
  --band-size N         Issues per band (default 100).
  --band-index K        Zero-based band to emit (default 0).
  --count               Print the total open-issue count instead of a band slice.
  --snapshot-out FILE   After fetching and sorting, write the full sorted JSON
                        array to FILE (so later bands reuse one fetch).
  --snapshot-in FILE    Read the pre-sorted JSON array from FILE instead of
                        fetching from GitHub (no gh call).

Writes a JSON array of the selected band to stdout (or the count with --count).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires an argument}"; shift 2 ;;
    --band-size) BAND_SIZE="${2:?--band-size requires an argument}"; shift 2 ;;
    --band-index) BAND_INDEX="${2:?--band-index requires an argument}"; shift 2 ;;
    --count) COUNT_MODE=1; shift ;;
    --snapshot-out) SNAPSHOT_OUT="${2:?--snapshot-out requires an argument}"; shift 2 ;;
    --snapshot-in) SNAPSHOT_IN="${2:?--snapshot-in requires an argument}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

: "${REPO:?--repo OWNER/REPO is required}"

if [[ ! "$BAND_SIZE" =~ ^[0-9]+$ ]] || [[ "$BAND_SIZE" -lt 1 ]]; then
  printf 'ERROR: --band-size must be a positive integer\n' >&2
  exit 2
fi
if [[ ! "$BAND_INDEX" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: --band-index must be a non-negative integer\n' >&2
  exit 2
fi

# FROM_GH gates whether the GH_LIMIT truncation warning applies: only fetched
# data can hit the limit, snapshot-in data was already bounded at write time.
FROM_GH=1
if [[ -n "$SNAPSHOT_IN" ]]; then
  # Snapshot path: no gh call, no non-GitHub guard. The file is the source.
  FROM_GH=0
  if [[ ! -r "$SNAPSHOT_IN" ]]; then
    printf 'ERROR: --snapshot-in file not found or unreadable: %s\n' "$SNAPSHOT_IN" >&2
    exit 1
  fi
  raw="$(cat "$SNAPSHOT_IN")"
  [[ -z "$raw" ]] && raw='[]'
else
  # Non-GitHub guard (same shape as bin/sweep-branches.sh): cron must not fail.
  if [[ -x "$BIN_DIR/is-github-dotcom-remote" ]]; then
    if ! "$BIN_DIR/is-github-dotcom-remote" >/dev/null 2>&1; then
      printf 'INFO: not a GitHub.com remote; sweep-issues skipped\n' >&2
      printf '[]\n'
      exit 0
    fi
  fi

  if ! command -v gh >/dev/null 2>&1; then
    printf 'INFO: gh CLI not found; sweep-issues skipped\n' >&2
    printf '[]\n'
    exit 0
  fi

  # A failed listing is NOT an empty band. The two are indistinguishable once the
  # result is `[]`, and the caller closes issues on the strength of this output —
  # so a fetch failure exits non-zero instead of degrading into "nothing to do".
  # The `[]` + exit 0 paths above are different: there the band is genuinely
  # inapplicable (no GitHub remote / no gh), which is a supported cron state.
  gh_rc=0
  raw="$("$BIN_DIR/run-with-timeout.sh" 120 gh issue list --repo "$REPO" --state open \
    --limit "$GH_LIMIT" --json number,title,body,labels,createdAt)" || gh_rc=$?
  if [[ "$gh_rc" -ne 0 ]]; then
    printf 'ERROR: gh issue list failed for %s (exit %s); the band is unknown\n' \
      "$REPO" "$gh_rc" >&2
    exit 1
  fi
  [[ -z "$raw" ]] && raw='[]'
fi

BAND_SIZE="$BAND_SIZE" BAND_INDEX="$BAND_INDEX" GH_LIMIT="$GH_LIMIT" \
COUNT_MODE="$COUNT_MODE" SNAPSHOT_OUT="$SNAPSHOT_OUT" FROM_GH="$FROM_GH" \
node -e '
const fs = require("fs");
const size = Number(process.env.BAND_SIZE);
const index = Number(process.env.BAND_INDEX);
const limit = Number(process.env.GH_LIMIT);
const countMode = process.env.COUNT_MODE === "1";
const snapshotOut = process.env.SNAPSHOT_OUT || "";
const fromGh = process.env.FROM_GH === "1";
let issues;
try {
  issues = JSON.parse(fs.readFileSync(0, "utf8") || "[]");
} catch (err) {
  process.stderr.write("ERROR: input is unparseable JSON: " + err.message + "\n");
  process.exit(2);
}
if (!Array.isArray(issues)) issues = [];
if (fromGh && issues.length >= limit) {
  process.stderr.write("WARNING: open-issue count reached the gh --limit of " + limit + "; later bands may be truncated\n");
}
issues.sort((a, b) => Number(a.number) - Number(b.number));
if (snapshotOut) {
  fs.writeFileSync(snapshotOut, JSON.stringify(issues) + "\n");
}
if (countMode) {
  process.stdout.write(String(issues.length) + "\n");
} else {
  process.stdout.write(JSON.stringify(issues.slice(index * size, (index + 1) * size)) + "\n");
}
' <<<"$raw"
