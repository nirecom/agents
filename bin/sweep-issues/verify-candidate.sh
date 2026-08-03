#!/usr/bin/env bash
#
# bin/sweep-issues/verify-candidate.sh — SI-4 field verification for ONE
# tier-2 survivor (a candidate that already passed the SI-3 human gate).
#
# Usage: verify-candidate.sh --issue N --tokens <csv> [--repo-root <dir>]
#                            [--timeout-seconds N] [--dry-run] [--apply]
#
# EVIDENCE ONLY — this script never emits a verdict. Judging is the SI-5 human
# gate's job. The issue body's own claims are deliberately NOT used as input:
# the whole point of the sweep is that stale issues describe a world that no
# longer exists.
#
# Three evidence channels, and no others:
#   (a) EVIDENCE-GREP   — `git grep -n -F` for each token's basename and for the
#                         identifier derived from it.
#   (b) EVIDENCE-RUN    — for an existing tests/*.sh token only, a real run via
#                         bin/run-with-timeout.sh. There is no un-wrapped path.
#                         --dry-run suppresses the run and reports what it would
#                         have executed, because executing a repository script is
#                         an effect and --dry-run promises none.
#   (c) EVIDENCE-ASSERT — PASS/FAIL counts PLUS every OBSERVED / `not ok` / SKIP
#                         line verbatim, so a green PASS count cannot be read as
#                         "all good" when assertions were skipped.
#
# SECURITY — two independent gates guard channel (b), because --tokens is
# free-form CSV that ultimately derives from attacker-authored issue text:
#   1. Grammar: every token is re-validated through
#      `scan-stale-paths.js --check-tokens` (the repository SSOT for the token
#      grammar and the no-`..` rule). Rejected tokens are reported and skipped.
#   2. Containment: the token's directory is resolved with `pwd -P` (symlinks
#      followed) and must land inside the resolved --repo-root before anything
#      is executed. Both gates must pass; neither is inferred from the other.
#
# Always exits 0: a failing verification is evidence, not an error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/sweep-write-mode.sh
source "$BIN_DIR/lib/sweep-write-mode.sh"
sweep_write_mode_init

ISSUE=""
TOKENS=""
REPO_ROOT="$PWD"
TIMEOUT_SECONDS=120

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues/verify-candidate.sh --issue N --tokens <csv>
                                            [--repo-root <dir>] [--timeout-seconds N]

Emits EVIDENCE-* lines for one tier-2 survivor. No verdict, no writes, exit 0.
EOF
  sweep_write_mode_usage_lines
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE="${2:?--issue requires an argument}"; shift 2 ;;
    --tokens) TOKENS="${2:-}"; shift 2 ;;
    --repo-root) REPO_ROOT="${2:?--repo-root requires an argument}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:?--timeout-seconds requires an argument}"; shift 2 ;;
    --dry-run) sweep_write_mode_dry_run; shift ;;
    --apply) sweep_write_mode_apply; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

: "${ISSUE:?--issue N is required}"

if [[ ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: --issue must be a positive integer, got: %s\n' "$ISSUE" >&2
  exit 2
fi

printf 'EVIDENCE-ISSUE: issue=%s tokens=%s\n' "$ISSUE" "${TOKENS:--}"

if [[ -z "$TOKENS" ]]; then
  printf 'EVIDENCE-NOTE: issue=%s no path tokens to verify\n' "$ISSUE"
  exit 0
fi

# Gate 1 — re-apply the token grammar at this consumer. SSOT: scan-stale-paths.js.
safe_tokens=()
while IFS=$'\t' read -r verdict token reason; do
  [[ -z "${verdict// /}" ]] && continue
  if [[ "$verdict" == "accept" ]]; then
    safe_tokens+=("$token")
  else
    printf 'EVIDENCE-REJECT: issue=%s token=%s reason=%s\n' \
      "$ISSUE" "$token" "${reason:-invalid}"
  fi
done < <(node "$SCRIPT_DIR/scan-stale-paths.js" --check-tokens "$TOKENS" || true)

if [[ ${#safe_tokens[@]} -eq 0 ]]; then
  printf 'EVIDENCE-NOTE: issue=%s no usable path tokens after validation\n' "$ISSUE"
  exit 0
fi

# Gate 2 — resolve a token inside REPO_ROOT, following symlinks, and refuse
# anything that lands outside it. Prints the resolved path; returns 1 on escape,
# on a missing parent directory, or on an unreadable root (fail closed).
resolve_within_repo_root() {
  local token="$1" root_real dir_real cand_real
  root_real="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || return 1
  dir_real="$(cd "$REPO_ROOT" 2>/dev/null && cd "$(dirname -- "$token")" 2>/dev/null && pwd -P)" || return 1
  cand_real="$dir_real/$(basename -- "$token")"
  [[ "$cand_real" == "$root_real"/* ]] || return 1
  printf '%s' "$cand_real"
}

for token in "${safe_tokens[@]}"; do
  if [[ -e "$REPO_ROOT/$token" ]]; then
    printf 'EVIDENCE-PATH: issue=%s token=%s state=exists\n' "$ISSUE" "$token"
  else
    printf 'EVIDENCE-PATH: issue=%s token=%s state=missing\n' "$ISSUE" "$token"
  fi

  # (a) grep for the basename and for the identifier derived from it.
  base="${token##*/}"
  ident="${base%.*}"
  for needle in "$base" "$ident"; do
    [[ -z "$needle" ]] && continue
    hits="$(git -C "$REPO_ROOT" grep -n -F -- "$needle" 2>/dev/null | head -20 || true)"
    if [[ -z "$hits" ]]; then
      printf 'EVIDENCE-GREP: issue=%s needle=%s hits=0\n' "$ISSUE" "$needle"
    else
      while IFS= read -r line; do
        printf 'EVIDENCE-GREP: issue=%s needle=%s %s\n' "$ISSUE" "$needle" "$line"
      done <<< "$hits"
    fi
  done

  # (b) real run, tests/*.sh only, always through the timeout wrapper.
  [[ "$token" == tests/*.sh ]] || continue
  [[ -f "$REPO_ROOT/$token" ]] || continue

  resolved=""
  if ! resolved="$(resolve_within_repo_root "$token")"; then
    printf 'EVIDENCE-REJECT: issue=%s token=%s reason=outside-repo-root\n' \
      "$ISSUE" "$token"
    continue
  fi
  if [[ ! -f "$resolved" ]]; then
    printf 'EVIDENCE-REJECT: issue=%s token=%s reason=not-a-regular-file\n' \
      "$ISSUE" "$token"
    continue
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'EVIDENCE-RUN: issue=%s token=%s skipped=dry-run would_run="bash %s" timeout=%ss\n' \
      "$ISSUE" "$token" "$token" "$TIMEOUT_SECONDS"
    continue
  fi

  printf 'EVIDENCE-RUN: issue=%s token=%s starting (timeout %ss)\n' \
    "$ISSUE" "$token" "$TIMEOUT_SECONDS"
  run_rc=0
  run_out="$( (cd "$REPO_ROOT" && "$BIN_DIR/run-with-timeout.sh" "$TIMEOUT_SECONDS" \
    bash "$resolved" </dev/null) 2>&1 )" || run_rc=$?
  printf 'EVIDENCE-RUN: issue=%s token=%s exit=%s\n' "$ISSUE" "$token" "$run_rc"

  # (c) counts plus the full text of every non-PASS assertion line.
  pass_n="$(grep -c 'PASS:' <<< "$run_out" 2>/dev/null || true)"
  fail_n="$(grep -c 'FAIL:' <<< "$run_out" 2>/dev/null || true)"
  printf 'EVIDENCE-ASSERT: issue=%s token=%s pass=%s fail=%s\n' \
    "$ISSUE" "$token" "${pass_n:-0}" "${fail_n:-0}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf 'EVIDENCE-ASSERT: issue=%s token=%s %s\n' "$ISSUE" "$token" "$line"
  done < <(grep -E 'OBSERVED|not ok|SKIP' <<< "$run_out" 2>/dev/null || true)
done

exit 0
