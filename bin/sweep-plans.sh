#!/bin/bash
# bin/sweep-plans.sh — reclaim stale ~/.workflow-plans/ session artifacts. A candidate is a
# group of files sharing a session-id prefix whose newest member is older than SWEEP_AGE_DAYS.
# A run deletes non-plan files by default, only lists plan / user-requested files, and always
# keeps unknown ones (classes: hooks/lib/plans-artifact-registry.js). --include-plan-and-user-requested
# opens the two-pass approval gate the /sweep-plans skill drives. Pass --dry-run to preview.
# Entrypoint only (rules/coding/file-split.md Pattern A); logic lives in bin/sweep-plans/.
# Exit codes: 0 normal completion; 1 unknown flag; 2 SWEEP_AGE_DAYS validation error,
# internal-protocol misuse, or approval gate verification failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"
# shellcheck source=lib/sweep-numeric.sh
source "$SCRIPT_DIR/lib/sweep-numeric.sh"
# shellcheck source=./sweep-plans/summary.sh
source "$SCRIPT_DIR/sweep-plans/summary.sh"
# shellcheck source=./sweep-plans/discover.sh
source "$SCRIPT_DIR/sweep-plans/discover.sh"
# shellcheck source=./sweep-plans/delete-passes.sh
source "$SCRIPT_DIR/sweep-plans/delete-passes.sh"

# ─── Defaults & flag parsing ───────────────────────────────────────────────

sweep_write_mode_init
CI_MODE=0
INCLUDE_APPROVAL=0
GATE_SESSION=""
GATE_ID=""
APPROVED_FILE=""
INTERNAL_FLAG_SEEN=0
SWEEP_AGE_DAYS="${SWEEP_AGE_DAYS:-30}"

sweep_validate_uint SWEEP_AGE_DAYS "$SWEEP_AGE_DAYS" 1 86400 2

usage() {
  cat <<'EOF'
Usage: sweep-plans.sh [options]

Options:
EOF
  sweep_write_mode_usage_lines
  cat <<'EOF'
  --include-plan-and-user-requested
                        Also offer plan and user-requested files of old sessions
                        for deletion through the /sweep-plans approval gate.
  --ci-mode             Emit exactly one JSON line on stdout; human-readable lines go to stderr.
  --sweep-age-days N    Age threshold in days (default 30; env SWEEP_AGE_DAYS).
  -h, --help            Show this help and exit.
EOF
}

protocol_error() {
  printf 'ERROR: sweep-plans: %s\n' "$1" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) sweep_write_mode_apply ;;
    --dry-run) sweep_write_mode_dry_run ;;
    --ci-mode) CI_MODE=1 ;;
    --include-plan-and-user-requested) INCLUDE_APPROVAL=1 ;;
    --sweep-age-days)
      shift
      SWEEP_AGE_DAYS="${1:?--sweep-age-days requires a value}"
      sweep_validate_uint SWEEP_AGE_DAYS "$SWEEP_AGE_DAYS" 1 86400 2
      ;;
    # Internal protocol with the /sweep-plans skill; not in usage.
    --gate-session|--gate-id|--approved-sessions-file)
      [[ $# -ge 2 ]] || protocol_error "$1 requires a value"
      case "$1" in
        --gate-session) GATE_SESSION="$2" ;;
        --gate-id) GATE_ID="$2" ;;
        --approved-sessions-file) APPROVED_FILE="$2" ;;
      esac
      INTERNAL_FLAG_SEEN=1
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'ERROR: unknown flag: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$INTERNAL_FLAG_SEEN" == "1" && "$INCLUDE_APPROVAL" == "0" ]]; then
  protocol_error "--gate-session, --gate-id and --approved-sessions-file need --include-plan-and-user-requested"
fi
if [[ -n "$APPROVED_FILE" || -n "$GATE_ID" ]]; then
  [[ -n "$GATE_SESSION" && -n "$GATE_ID" && -n "$APPROVED_FILE" ]] \
    || protocol_error "pass 2 needs --gate-session, --gate-id and --approved-sessions-file together"
  [[ "$GATE_ID" =~ ^[0-9a-f]{32}$ ]] || protocol_error "approval gate artifact missing or mismatched; nothing deleted"
fi
PASS2=0
if [[ -n "$APPROVED_FILE" ]]; then PASS2=1; fi

# ─── PLANS_DIR resolution ──────────────────────────────────────────────────

if [[ -x "$SCRIPT_DIR/workflow-plans-dir" ]]; then
  PLANS_DIR="$("$SCRIPT_DIR/workflow-plans-dir" 2>/dev/null || echo "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")"
else
  PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
fi

if [[ ! -d "$PLANS_DIR" ]]; then
  # Pass 2 binds to the plans dir pass 1 saw; a vanished dir is a mismatch.
  if [[ "$PASS2" == "1" ]]; then _gate_fail "approval gate artifact missing or mismatched"; fi
  sweep_plans_summary_no_dir
  exit 0
fi
# Scan, revival recheck and gate all act on one physical dir (find does not follow a
# symlinked start dir); a symlink retargeted between passes is then a gate mismatch.
if ! PLANS_DIR="$(cd "$PLANS_DIR" 2>/dev/null && pwd -P)"; then
  if [[ "$PASS2" == "1" ]]; then _gate_fail "approval gate artifact missing or mismatched"; fi
  sweep_plans_summary_no_dir
  exit 0
fi

# ─── Passes (pass 2 verification precedes every deletion) ─────────────────

sweep_plans_counters_init
now_epoch="$(date +%s)"
sweep_plans_scan
sweep_plans_classify
sweep_plans_select
if [[ "$PASS2" == "1" ]]; then
  sweep_plans_gate_verify
fi
sweep_plans_list
if [[ "$INCLUDE_APPROVAL" == "1" && -n "$GATE_SESSION" && "$PASS2" == "0" && "$DRY_RUN" == "0" ]]; then
  sweep_plans_gate_write
fi
sweep_plans_delete
sweep_plans_gate_block
sweep_plans_summary

exit 0
