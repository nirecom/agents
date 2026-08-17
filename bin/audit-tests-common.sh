#!/usr/bin/env bash
# audit-tests-common.sh — Retire checker for common (non-issue-specific) tests.
# Usage: bin/audit-tests-common.sh [--dry-run] [--apply] [--offline]
#                                  [--stale-months N] [--format text|json]
#                                  [--fix-headers] [--dup-groups]
# Exit:  0 = orphans found, 1 = no orphans, 2 = error
# Writes by default: a flagless run DELETES orphans (git rm); --dry-run reports
# only. --dup-groups is read-only: a corpus-wide `# Tests:` duplicate inventory
# as TSV, identical from either entrypoint (bin/lib/test-dup-group.sh).
# Scans top-level tests/*.sh EXCEPT tests/feature-<N>-*.sh; an ORPHAN is a file
# whose every `# Tests:` path is gone, gated on the filename's issue reference.

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
# shellcheck source=lib/test-dup-group.sh
source "$SCRIPT_DIR/lib/test-dup-group.sh"

STALE_MONTHS=3
OFFLINE=0
FORMAT=text
FIX_HEADERS=0
FIX_APPLY=0
DUP_GROUPS=0
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
    --dup-groups) DUP_GROUPS=1; shift ;;
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
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
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

# Read-only inventory mode. Placed before gh init and cutoff computation: it
# needs neither, so it stays offline-safe and timeout-free. in_common_scope is
# defined below and deliberately NOT applied — the inventory is corpus-wide (S3).
if [[ "$DUP_GROUPS" -eq 1 ]]; then
  tdg_mode_guard "$DUP_GROUPS" "$FIX_APPLY" "$FIX_HEADERS" "$FORMAT" || exit 2
  tdg_run "$REPO_ROOT" && exit 0
  exit 1
fi

TODAY="$(date +%Y-%m-%d)"
trp_compute_cutoff "$STALE_MONTHS" >/dev/null
CUTOFF_DATE="$TRP_CUTOFF_DATE"
TRP_GH_TIMEOUT="${GH_TIMEOUT:-30}"

# in_common_scope <relpath> — top-level, non-archived, non-issue-specific.
in_common_scope() {
  local rel="$1" name
  name="$(basename "$rel")"
  case "$rel" in
    tests/_archive/*) return 1 ;;
  esac
  [[ "$(trp_scope_of "$name")" == "common" ]]
}

if [[ "$FIX_HEADERS" -eq 1 ]]; then
  for testfile in tests/*.sh; do
    [[ -e "$testfile" ]] || continue
    in_common_scope "$testfile" || continue
    _fix_headers_report "$testfile"
    if [[ "$APPLY" -eq 1 && "$FIX_APPLY" -eq 1 ]]; then
      _fix_headers_apply "$testfile"
    fi
  done
  exit 0
fi

trp_init_gh "$OFFLINE"
OFFLINE="$TRP_OFFLINE"

DIAG_FILES=()
DIAG_KINDS=()
ORPHANS=()
DELETE_FAILED=0
JSON_ITEMS=()

if [[ "$FORMAT" == "text" ]]; then
  echo "# audit-tests-common.sh report — ${TODAY}"
  echo "# Scope: top-level tests/*.sh excluding issue-specific feature-<N>-*.sh"
  echo "# Criteria: every '# Tests:' target is missing — the filename's issue reference gates deletion only"
  echo "# Cutoff: ${CUTOFF_DATE} (stale-months: ${STALE_MONTHS})"
  if [[ "$OFFLINE" -eq 1 ]]; then
    echo "# Mode: OFFLINE (orphans are still reported; deletion of issue-referencing files is held)"
  fi
  echo ""
fi

for testfile in tests/*.sh; do
  [[ -e "$testfile" ]] || continue
  in_common_scope "$testfile" || continue
  base="$(basename "$testfile")"

  trp_survival_verdict "$REPO_ROOT" "$testfile" >/dev/null
  verdict="$TRP_VERDICT"

  case "$verdict" in
    malformed)
      DIAG_FILES+=("$testfile"); DIAG_KINDS+=("malformed_header")
      if [[ "$FORMAT" == "text" ]]; then echo "MALFORMED_HEADER: ${testfile}"; fi
      continue
      ;;
    no-header)
      DIAG_FILES+=("$testfile"); DIAG_KINDS+=("no_tests_header")
      if [[ "$FORMAT" == "text" ]]; then echo "NO_TESTS_HEADER: ${testfile}"; fi
      continue
      ;;
    orphan) ;;
    *) continue ;;
  esac

  tokens_all=("${TRP_TOKENS_ALL[@]:-}")
  tokens_missing=("${TRP_TOKENS_MISSING[@]:-}")
  tests_csv="$TRP_TESTS_CSV"

  trp_unit_of "$REPO_ROOT" "$testfile"
  sibling="$TRP_SIBLING"
  sib_count="$TRP_SIBLING_COUNT"
  unit_paths=("${TRP_UNIT_PATHS[@]}")

  scope="$(trp_scope_of "$base")"
  ref="$(trp_issue_ref "$base")"
  meta="none"
  if [[ "$ref" == "explicit" ]]; then
    issue_num="$(trp_issue_number "$base")"
    trp_fetch_issue_meta "$issue_num" >/dev/null
    meta="$TRP_ISSUE_META"
  fi
  trp_delete_gate "$verdict" "$scope" "$ref" "$meta" >/dev/null
  gate="$TRP_GATE"

  ORPHANS+=("$testfile")

  if [[ "$FORMAT" == "text" ]]; then
    echo "ORPHAN: ${testfile}"
    echo "  Tests: ${tests_csv}"
    echo "  Missing paths: $(IFS=','; echo "${tokens_missing[*]}")"
    if [[ -n "$sibling" ]]; then
      echo "  Sibling folder: ${sibling}/ (${sib_count} files)"
      echo "  Deletion unit: ${testfile} ${sibling}/"
    else
      echo "  Deletion unit: ${testfile}"
    fi
  fi

  hold_token="$(trp_gate_line_token "$gate")"
  if [[ -n "$hold_token" ]]; then
    if [[ "$FORMAT" == "text" ]]; then echo "${hold_token}: ${testfile}"; fi
  elif [[ "$APPLY" -eq 1 ]]; then
    if trp_git_rm_unit "${unit_paths[@]}"; then
      if [[ "$FORMAT" == "text" ]]; then echo "DELETED: ${testfile}"; fi
    else
      DELETE_FAILED=1
    fi
  fi
  if [[ "$FORMAT" == "text" ]]; then echo ""; fi

  if [[ "$FORMAT" == "json" ]]; then
    sib_json=""
    if [[ -n "$sibling" ]]; then sib_json="${sibling}/"; fi
    JSON_ITEMS+=("$(printf '{"file":"%s","tests_paths":%s,"missing_paths":%s,"sibling":"%s","sibling_file_count":%s,"delete_gate":"%s"}' \
      "$(trp_json_escape "$testfile")" \
      "$(trp_json_array "${tokens_all[@]}")" \
      "$(trp_json_array "${tokens_missing[@]}")" \
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
  orph_json=""
  for item in "${JSON_ITEMS[@]:-}"; do
    if [[ -z "$item" ]]; then continue; fi
    if [[ -n "$orph_json" ]]; then orph_json+=","; fi
    orph_json+="$item"
  done
  printf '{"generated":"%s","cutoff":"%s","stale_months":%s,"offline":%s,"diagnostics":[%s],"orphans":[%s]}\n' \
    "$TODAY" "$CUTOFF_DATE" "$STALE_MONTHS" "$OFFLINE" "$diag_json" "$orph_json"
else
  sweep_write_mode_footer
fi

if [[ "$DELETE_FAILED" -eq 1 ]]; then
  exit 2
fi
if [[ "${#ORPHANS[@]}" -eq 0 ]]; then
  exit 1
fi
exit 0
