#!/usr/bin/env bash
# bin/verify-case-embed.sh — the five-check gate for one case-marker embedding rewrite.
# Usage: verify-case-embed.sh <after-file> --relpath <repo-relpath> [--before <before-file>]
#        [--merged-report <report.txt>] [--backup-dir <dir>]
# Prints CHECK<n>\t<PASS|FAIL|SKIP>\t<detail> per check (static mode: 1 3 4 5; with --before:
# 1 2 3 4 5) and EXEMPT\t<token>\t<case-name> per MERGED_TARGET exemption.
# Exit 0: no FAIL. Exit 1: a FAIL. Exit 2: usage error, unusable library, or a non-empty / symlinked backup dir.
# The after-file stands in at <relpath> while it is judged; the original waits in --backup-dir
# (a leftover file there means "restore needed"). Contract: docs/architecture/claude-code/sweep-tests-embed-cases.md.
set -euo pipefail

VCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VCE_TOOL="$(cd "$VCE_DIR/.." && pwd)"
# The judged repo is the caller's (cwd); the tool's own checkout may be another one.
VCE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

vce_usage() {
  printf 'verify-case-embed.sh: %s\n' "$1" >&2
  printf 'Usage: verify-case-embed.sh <after-file> --relpath <repo-relpath> [--before <file>] [--merged-report <file>] [--backup-dir <dir>]\n' >&2
  exit 2
}

# vce_abs <path> — absolute form against the invocation directory.
vce_abs() { case "$1" in /* | [A-Za-z]:/*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }

VCE_AFTER="" VCE_REL="" VCE_BEFORE="" VCE_REPORT="" VCE_BK=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --relpath | --before | --merged-report | --backup-dir)
      [[ "$#" -ge 2 && -n "$2" ]] || vce_usage "$1 needs a value"
      case "$1" in
        --relpath) VCE_REL="$2" ;;
        --before) VCE_BEFORE="$(vce_abs "$2")" ;;
        --merged-report) VCE_REPORT="$(vce_abs "$2")" ;;
        --backup-dir) VCE_BK="$(vce_abs "$2")" ;;
      esac
      shift 2 ;;
    -h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) vce_usage "unknown option: $1" ;;
    *) [[ -z "$VCE_AFTER" ]] || vce_usage "more than one after-file"; VCE_AFTER="$(vce_abs "$1")"; shift ;;
  esac
done
[[ -n "$VCE_AFTER" ]] || vce_usage "after-file required"
[[ -n "$VCE_REL" ]] || vce_usage "--relpath required"
[[ "$VCE_REL" != /* && "$VCE_REL" != *..* ]] || vce_usage "--relpath must be repo-relative: $VCE_REL"
[[ -f "$VCE_AFTER" ]] || vce_usage "after-file not found: $VCE_AFTER"
[[ -z "$VCE_BEFORE" || -f "$VCE_BEFORE" ]] || vce_usage "before-file not found: $VCE_BEFORE"
[[ -z "$VCE_REPORT" || -f "$VCE_REPORT" ]] || vce_usage "merged report not found: $VCE_REPORT"
cd "$VCE_ROOT"
[[ -f "$VCE_REL" ]] || vce_usage "relpath not found in $VCE_ROOT: $VCE_REL"

for _vce_lib in "$VCE_TOOL/bin/lib/case-record-reader.sh" "$VCE_DIR/verify-case-embed/checks.sh" "$VCE_DIR/verify-case-embed/run-compare.sh"; do
  [[ -f "$_vce_lib" ]] || { printf 'verify-case-embed.sh: library unavailable: %s\n' "$_vce_lib" >&2; exit 2; }
done
# shellcheck source=lib/case-record-reader.sh
. "$VCE_TOOL/bin/lib/case-record-reader.sh" || { printf 'verify-case-embed.sh: case-record-reader unusable\n' >&2; exit 2; }
# shellcheck source=verify-case-embed/checks.sh
. "$VCE_DIR/verify-case-embed/checks.sh"
tlr_load || { printf 'verify-case-embed.sh: registry unreadable\n' >&2; exit 2; }

if [[ -z "$VCE_BK" ]]; then
  VCE_BK="$(mktemp -d "${TMPDIR:-/tmp}/verify-case-embed.XXXXXX")"
  printf 'verify-case-embed.sh: backup dir %s (restore %s from it if this run is killed)\n' "$VCE_BK" "$VCE_REL" >&2
fi
if [[ -L "${VCE_BK%/}" ]]; then
  printf 'verify-case-embed.sh: backup dir is a symlink (refusing to write through it): %s\n' "$VCE_BK" >&2
  exit 2
fi
mkdir -p "$VCE_BK"
if [[ -n "$(ls -A "$VCE_BK" 2>/dev/null)" ]]; then
  printf 'verify-case-embed.sh: backup dir not empty (an interrupted run left it; restore first): %s\n' "$VCE_BK" >&2
  exit 2
fi
VCE_BK_FILE="$VCE_BK/${VCE_REL##*/}"

vce_restore() {
  if [[ -f "$VCE_BK_FILE" && ! -L "$VCE_BK_FILE" ]]; then cp "$VCE_BK_FILE" "$VCE_REL" && rm -f "$VCE_BK_FILE"; fi
}
trap vce_restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Static checks judge the after-file at its repo path.
cp "$VCE_REL" "$VCE_BK_FILE"
cp "$VCE_AFTER" "$VCE_REL"
vce_static_checks "$VCE_REL" "$VCE_REPORT"
vce_restore

VCE_LINE2=""
if [[ -n "$VCE_BEFORE" ]]; then
  VCE_LINE2="$(bash "$VCE_DIR/verify-case-embed/run-compare.sh" "$VCE_REL" "$VCE_AFTER" "$VCE_BEFORE" "$VCE_BK")" || true
  [[ "$VCE_LINE2" == CHECK2$'\t'* ]] || VCE_LINE2=$'CHECK2\tFAIL\tinconclusive: comparison did not report'
fi

printf '%s\n' "$VCE_LINE1"
[[ -z "$VCE_LINE2" ]] || printf '%s\n' "$VCE_LINE2"
printf '%s\n' "$VCE_LINE3" "$VCE_LINE4" "$VCE_LINE5"
[[ -z "$VCE_EXEMPT" ]] || printf '%s' "$VCE_EXEMPT"

for _vce_line in "$VCE_LINE1" "$VCE_LINE2" "$VCE_LINE3" "$VCE_LINE4" "$VCE_LINE5"; do
  [[ "$_vce_line" != *$'\t'FAIL$'\t'* ]] || exit 1
done
exit 0
