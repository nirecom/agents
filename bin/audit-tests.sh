#!/usr/bin/env bash
# audit-tests.sh — Retire checker for issue-specific test files.
#
# Usage: bin/audit-tests.sh [--dry-run] [--stale-months N] [--offline]
#                           [--format text|json] [--fix-headers]
# Exit:  0 = candidates found, 1 = no candidates, 2 = error
#
# Writes by default: a flagless run DELETES candidates (git rm), and
# --fix-headers rewrites headers in place. Pass --dry-run to report only.
#
# Scans top-level tests/feature-NNN-*.sh. A file becomes a CANDIDATE when every
# path in its `# Tests:` header is gone (target survival) — the issue's state is
# NOT part of that filter. Issue metadata is consulted only at deletion time:
# a candidate whose issue is open, recently closed, or unreadable is reported
# and kept (SKIP_DELETE_*). A file plus its sibling tests/<stem>/ folder is one
# retire unit. Malformed and missing headers are reported as diagnostics.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-frontmatter-constants.sh
source "$SCRIPT_DIR/lib/test-frontmatter-constants.sh"
# shellcheck source=lib/test-frontmatter-fix.sh
source "$SCRIPT_DIR/lib/test-frontmatter-fix.sh"
# shellcheck source=lib/test-retire-predicate.sh
source "$SCRIPT_DIR/lib/test-retire-predicate.sh"
# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"

STALE_MONTHS=3
OFFLINE=0
FORMAT=text
FIX_HEADERS=0
FIX_APPLY=0
sweep_write_mode_init

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stale-months)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --stale-months requires an argument" >&2
        exit 2
      fi
      STALE_MONTHS="$2"
      shift 2
      ;;
    --offline) OFFLINE=1; shift ;;
    --fix-headers) FIX_HEADERS=1; shift ;;
    --apply) sweep_write_mode_apply; FIX_APPLY=1; shift ;;
    --dry-run) sweep_write_mode_dry_run; shift ;;
    --format)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --format requires an argument (text|json)" >&2
        exit 2
      fi
      FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      sweep_write_mode_usage_lines
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$FORMAT" != "text" && "$FORMAT" != "json" ]]; then
  echo "ERROR: --format must be text or json (got: $FORMAT)" >&2
  exit 2
fi
if [[ ! "$STALE_MONTHS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --stale-months must be a non-negative integer (got: $STALE_MONTHS)" >&2
  exit 2
fi

# Fail closed: with apply-by-default, an unresolvable repo root must delete
# nothing rather than operate against whatever tests/ the CWD happens to expose.
if ! REPO_ROOT="$(trp_require_repo_root)"; then
  echo "ERROR: not inside a git repository — cannot resolve the repo root" >&2
  exit 2
fi
cd "$REPO_ROOT"
if [[ ! -d tests ]]; then
  echo "ERROR: tests/ directory not found under $REPO_ROOT" >&2
  exit 2
fi

TODAY="$(date +%Y-%m-%d)"
trp_compute_cutoff "$STALE_MONTHS" >/dev/null
CUTOFF_DATE="$TRP_CUTOFF_DATE"
TRP_GH_TIMEOUT="${GH_TIMEOUT:-30}"

# ── header-repair mode is a separate job, not part of the retire pass ────────
if [[ "$FIX_HEADERS" -eq 1 ]]; then
  for dispatcher in tests/feature-[0-9]*-*.sh; do
    [[ -e "$dispatcher" ]] || continue
    _fix_headers_report "$dispatcher"
    if [[ "$APPLY" -eq 1 && "$FIX_APPLY" -eq 1 ]]; then
      _fix_headers_apply "$dispatcher"
    fi
  done
  exit 0
fi

trp_init_gh "$OFFLINE"
OFFLINE="$TRP_OFFLINE"

DIAG_FILES=()
DIAG_KINDS=()
CANDIDATES=()
DELETE_FAILED=0
JSON_ITEMS=()

if [[ "$FORMAT" == "text" ]]; then
  echo "# audit-tests.sh report — ${TODAY}"
  echo "# Scope: top-level tests/feature-<N>-*.sh (issue-specific)"
  echo "# Criteria: every '# Tests:' target is missing — issue state gates deletion only"
  echo "# Cutoff: ${CUTOFF_DATE} (stale-months: ${STALE_MONTHS})"
  if [[ "$OFFLINE" -eq 1 ]]; then
    echo "# Mode: OFFLINE (candidates are still reported; deletion of issue-referencing files is held)"
  fi
  echo ""
fi

for dispatcher in tests/feature-[0-9]*-*.sh; do
  [[ -e "$dispatcher" ]] || continue
  base="$(basename "$dispatcher")"
  [[ "$base" =~ ^feature-([0-9]+)- ]] || continue
  issue_num="${BASH_REMATCH[1]}"

  # Primary filter: does the target still survive? (never the issue's state)
  trp_survival_verdict "$REPO_ROOT" "$dispatcher" >/dev/null
  verdict="$TRP_VERDICT"

  case "$verdict" in
    malformed)
      DIAG_FILES+=("$dispatcher"); DIAG_KINDS+=("malformed_header")
      if [[ "$FORMAT" == "text" ]]; then echo "MALFORMED_HEADER: ${dispatcher}"; fi
      continue
      ;;
    no-header)
      DIAG_FILES+=("$dispatcher"); DIAG_KINDS+=("no_tests_header")
      if [[ "$FORMAT" == "text" ]]; then echo "NO_TESTS_HEADER: ${dispatcher}"; fi
      continue
      ;;
    orphan) ;;
    *) continue ;;
  esac

  trp_unit_of "$REPO_ROOT" "$dispatcher"
  sibling="$TRP_SIBLING"
  sib_count="$TRP_SIBLING_COUNT"
  unit_paths=("${TRP_UNIT_PATHS[@]}")

  disp_date="$(git log -1 --format=%cd --date=short -- "$dispatcher" 2>/dev/null || true)"
  sib_date=""
  if [[ -n "$sibling" ]]; then
    sib_date="$(git log -1 --format=%cd --date=short -- "$sibling" 2>/dev/null || true)"
  fi
  last_commit="$disp_date"
  if [[ -n "$sib_date" && "$sib_date" > "$last_commit" ]]; then last_commit="$sib_date"; fi

  trp_fetch_issue_meta "$issue_num" >/dev/null
  meta="$TRP_ISSUE_META"
  case "$meta" in
    closed:*) issue_state="closed"; issue_closed_date="${meta#closed:}" ;;
    open)     issue_state="open";   issue_closed_date="" ;;
    state:*)  issue_state="${meta#state:}"; issue_closed_date="" ;;
    *)        issue_state="unknown"; issue_closed_date="" ;;
  esac

  scope="$(trp_scope_of "$base")"
  ref="$(trp_issue_ref "$base")"
  trp_delete_gate "$verdict" "$scope" "$ref" "$meta" >/dev/null
  gate="$TRP_GATE"

  CANDIDATES+=("$dispatcher")

  if [[ "$FORMAT" == "text" ]]; then
    echo "CANDIDATE: ${dispatcher}"
    echo "  Issue: #${issue_num} (${issue_state}, closed: ${issue_closed_date:-n/a})"
    echo "  Last-commit: ${last_commit:-unknown} (dispatcher: ${disp_date:-unknown} | sibling: ${sib_date:-n/a})"
    if [[ -n "$sibling" ]]; then
      echo "  Sibling folder: ${sibling}/ (${sib_count} files)"
      echo "  Deletion unit: ${dispatcher} ${sibling}/"
    else
      echo "  Sibling folder: (none)"
      echo "  Deletion unit: ${dispatcher}"
    fi
  fi

  hold_token="$(trp_gate_line_token "$gate")"
  if [[ -n "$hold_token" ]]; then
    if [[ "$FORMAT" == "text" ]]; then echo "${hold_token}: ${dispatcher}"; fi
  elif [[ "$APPLY" -eq 1 ]]; then
    if trp_git_rm_unit "${unit_paths[@]}"; then
      if [[ "$FORMAT" == "text" ]]; then echo "DELETED: ${dispatcher}"; fi
    else
      DELETE_FAILED=1
    fi
  fi
  if [[ "$FORMAT" == "text" ]]; then echo ""; fi

  if [[ "$FORMAT" == "json" ]]; then
    sib_json=""
    if [[ -n "$sibling" ]]; then sib_json="${sibling}/"; fi
    JSON_ITEMS+=("$(printf '{"dispatcher":"%s","issue":%s,"state":"%s","closed_at":"%s","last_commit":"%s","dispatcher_date":"%s","sibling_date":"%s","sibling":"%s","sibling_file_count":%s,"delete_gate":"%s"}' \
      "$(trp_json_escape "$dispatcher")" "$issue_num" "$(trp_json_escape "$issue_state")" \
      "$(trp_json_escape "$issue_closed_date")" "$(trp_json_escape "$last_commit")" \
      "$(trp_json_escape "$disp_date")" "$(trp_json_escape "$sib_date")" \
      "$(trp_json_escape "$sib_json")" "$sib_count" "$(trp_json_escape "$gate")")")
  fi
done

if [[ "$FORMAT" == "json" ]]; then
  diag_json=""
  for i in "${!DIAG_FILES[@]}"; do
    if [[ -n "$diag_json" ]]; then diag_json+=","; fi
    diag_json+="$(printf '{"file":"%s","kind":"%s"}' \
      "$(trp_json_escape "${DIAG_FILES[$i]}")" "${DIAG_KINDS[$i]}")"
  done
  cand_json=""
  for item in "${JSON_ITEMS[@]:-}"; do
    if [[ -z "$item" ]]; then continue; fi
    if [[ -n "$cand_json" ]]; then cand_json+=","; fi
    cand_json+="$item"
  done
  printf '{"generated":"%s","cutoff":"%s","stale_months":%s,"offline":%s,"diagnostics":[%s],"candidates":[%s]}\n' \
    "$TODAY" "$CUTOFF_DATE" "$STALE_MONTHS" "$OFFLINE" "$diag_json" "$cand_json"
else
  sweep_write_mode_footer
fi

if [[ "$DELETE_FAILED" -eq 1 ]]; then
  exit 2
fi
if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  exit 1
fi
exit 0
