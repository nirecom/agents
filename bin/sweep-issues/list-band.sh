#!/usr/bin/env bash
#
# bin/sweep-issues/list-band.sh — SI-1 band fetcher.
#
# Emits one deterministic slice of the open-issue list as a JSON array on
# stdout, so that a sweep run has a bounded, resumable unit of work.
#
# Usage: list-band.sh --repo OWNER/REPO [--band-size N] [--band-index K]
#
# Issues are sorted by number ASCENDING before slicing, so band K always means
# the same set for a given repository snapshot regardless of gh's return order.
# Read-only: no writes, no close helpers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO=""
BAND_SIZE=100
BAND_INDEX=0
GH_LIMIT=1000

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues/list-band.sh --repo OWNER/REPO [--band-size N] [--band-index K]

  --repo OWNER/REPO     Repository to list open issues from (required).
  --band-size N         Issues per band (default 100).
  --band-index K        Zero-based band to emit (default 0).

Writes a JSON array of the selected band to stdout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires an argument}"; shift 2 ;;
    --band-size) BAND_SIZE="${2:?--band-size requires an argument}"; shift 2 ;;
    --band-index) BAND_INDEX="${2:?--band-index requires an argument}"; shift 2 ;;
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

BAND_SIZE="$BAND_SIZE" BAND_INDEX="$BAND_INDEX" GH_LIMIT="$GH_LIMIT" \
node -e '
const size = Number(process.env.BAND_SIZE);
const index = Number(process.env.BAND_INDEX);
const limit = Number(process.env.GH_LIMIT);
let issues;
try {
  issues = JSON.parse(require("fs").readFileSync(0, "utf8") || "[]");
} catch (err) {
  process.stderr.write("ERROR: gh returned unparseable JSON: " + err.message + "\n");
  process.exit(2);
}
if (!Array.isArray(issues)) issues = [];
if (issues.length >= limit) {
  process.stderr.write("WARNING: open-issue count reached the gh --limit of " + limit + "; later bands may be truncated\n");
}
issues.sort((a, b) => Number(a.number) - Number(b.number));
process.stdout.write(JSON.stringify(issues.slice(index * size, (index + 1) * size)) + "\n");
' <<<"$raw"
