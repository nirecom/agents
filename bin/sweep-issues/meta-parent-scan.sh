#!/usr/bin/env bash
#
# bin/sweep-issues/meta-parent-scan.sh — SI-7 meta-parent verdict scanner.
#
# PURE DETECTOR: writes nothing and closes nothing. Every close in the
# /sweep-issues family goes through bin/sweep-issues/close-batch.sh, which is
# the single place --dry-run has to be honoured.
#
# Usage: meta-parent-scan.sh --repo OWNER/REPO
#
# Output TSV (headerless): number / verdict / open_count / title
#   verdict ∈ all-closed | has-open | no-sub-issues | error
#   open_count is `-` when the exit code does not carry a count.
#
# Exit codes of bin/github-issues/parent-all-closed-check.sh are NOT
# reinterpreted: 0 = all sub-issues closed, 1 = one or more open, 2 = no
# sub-issues, 3 = error.
#
# DELIBERATE DIVERGENCE from bin/github-issues/issue-close-finalize-triage.sh:
# that script treats exit 2 (no sub-issues) as equivalent to exit 0, because it
# serves a human closing one named issue on purpose. This scanner feeds an
# UNATTENDED batch, where auto-closing a meta parent that has no sub-issues at
# all has no evidence behind it. Only `all-closed` is a tier-1 close candidate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_DIR="$BIN_DIR/github-issues"

REPO=""

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues/meta-parent-scan.sh --repo OWNER/REPO

Emits a headerless TSV: number / verdict / open_count / title.
Read-only — closing is done by bin/sweep-issues/close-batch.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires an argument}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

: "${REPO:?--repo OWNER/REPO is required}"

if ! command -v gh >/dev/null 2>&1; then
  printf 'INFO: gh CLI not found; meta-parent scan skipped\n' >&2
  exit 0
fi

# "no meta parents" and "the listing failed" must not collapse into the same
# empty output: the caller reads an empty result as "tier 1 has nothing to do".
gh_rc=0
raw="$("$BIN_DIR/run-with-timeout.sh" 120 gh issue list --repo "$REPO" --state open \
  --label meta --json number,title)" || gh_rc=$?
if [[ "$gh_rc" -ne 0 ]]; then
  printf 'ERROR: gh issue list --label meta failed for %s (exit %s); tier 1 is unknown\n' \
    "$REPO" "$gh_rc" >&2
  exit 1
fi
[[ -z "$raw" ]] && raw='[]'

# Flatten to `number<TAB>title`; titles are stripped of tabs/newlines so the
# downstream TSV stays 4 columns.
parents="$(node -e '
let rows;
try {
  rows = JSON.parse(require("fs").readFileSync(0, "utf8") || "[]");
} catch (err) {
  process.stderr.write("ERROR: gh returned unparseable JSON: " + err.message + "\n");
  process.exit(2);
}
if (!Array.isArray(rows)) rows = [];
for (const r of rows) {
  const title = String(r.title === undefined ? "" : r.title).replace(/[\t\r\n]+/g, " ");
  process.stdout.write(r.number + "\t" + title + "\n");
}
' <<<"$raw")"

[[ -z "$parents" ]] && exit 0

while IFS=$'\t' read -r number title; do
  [[ -z "${number// /}" ]] && continue

  rc=0
  "$HELPER_DIR/parent-all-closed-check.sh" "$REPO" "$number" >/dev/null 2>&1 || rc=$?

  case "$rc" in
    0) verdict="all-closed" ;;
    1) verdict="has-open" ;;
    2) verdict="no-sub-issues" ;;
    *) verdict="error" ;;
  esac

  printf '%s\t%s\t-\t%s\n' "$number" "$verdict" "$title"
done <<<"$parents"
