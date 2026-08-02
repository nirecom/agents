#!/usr/bin/env bash
#
# bin/sweep-supervisor-state.sh
#
# #1799 remediation: removes the escape_hatch_event records that leaking test
# suites wrote into real supervisor state files, from FINISHED sessions only.
#
# THE ONE EXCEPTION to the /sweep family's apply-by-default rule: this member is
# DRY-RUN BY DEFAULT. It deletes from a governance audit trail, not from a
# regenerable derivative, so the blast radius justifies the inversion.
#
# The live-session scope guard is unconditional. There is no --include-live.
# --session narrows the target set; it never relaxes the guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$SCRIPT_DIR/sweep-supervisor-state/engine.js"
SIGNATURES="$SCRIPT_DIR/sweep-supervisor-state/signatures.js"

# shellcheck source=bin/lib/sweep-write-mode.sh
. "$SCRIPT_DIR/lib/sweep-write-mode.sh"

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

usage() {
    cat <<'USAGE'
Usage: sweep-supervisor-state.sh [options]

Removes #1799 test-contamination records from supervisor state files.

Options:
  --apply               Write the changes (backup first). Default is DRY-RUN.
  --dry-run             Explicit dry-run (the default).
  --ci-mode             Emit a single-line JSON summary instead of prose.
  --list-signatures     Print the reason allowlist and exit 0.
  --session <SID>       Narrow the target set to one session. Never relaxes
                        the live-session guard.
  --help                Show this help and exit 0.

Scope guard (unconditional, no override flag exists):
  alert_phase=pending, audit_phase pending/in_progress, last_updated within
  24h, and the currently running session are always skipped.
USAGE
}

# Dry-run by default — the deliberate family exception.
sweep_write_mode_dry_run

CI_MODE=0
SESSION=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply)            sweep_write_mode_apply ;;
        --dry-run)          sweep_write_mode_dry_run ;;
        --ci-mode)          CI_MODE=1 ;;
        --list-signatures)  node "$(node_path "$SIGNATURES")"; exit 0 ;;
        --session)          SESSION="${2:-}"; shift ;;
        --help|-h)          usage; exit 0 ;;
        *)
            printf 'sweep-supervisor-state: unknown flag: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
if [ ! -d "$PLANS_DIR" ]; then
    if [ "$CI_MODE" = "1" ]; then
        printf '{"scanned":0,"skipped_live":0,"skipped_recent":0,"files_contaminated":0,"files_modified":0,"records_removed":0,"files_emptied":0,"files_skipped_unparsable":0,"backup_dir":"","errors":["plans dir not found"]}\n'
    else
        printf 'sweep-supervisor-state: plans dir not found: %s\n' "$PLANS_DIR"
    fi
    exit 0
fi

ENGINE_ARGS=(--plans-dir "$(node_path "$PLANS_DIR")")
[ "${APPLY:-0}" = "1" ] && ENGINE_ARGS+=(--apply)
[ -n "$SESSION" ] && ENGINE_ARGS+=(--session "$SESSION")
[ -n "${CLAUDE_SESSION_ID:-}" ] && ENGINE_ARGS+=(--current-session "$CLAUDE_SESSION_ID")

SUMMARY="$(node "$(node_path "$ENGINE")" "${ENGINE_ARGS[@]}")"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'sweep-supervisor-state: engine failed (exit %s)\n' "$RC" >&2
    exit "$RC"
fi

if [ "$CI_MODE" = "1" ]; then
    printf '%s\n' "$SUMMARY"
    exit 0
fi

printf '%s' "$SUMMARY" | node -e '
let b = "";
process.stdin.on("data", (c) => (b += c));
process.stdin.on("end", () => {
  let s;
  try { s = JSON.parse(b.trim()); } catch (e) { process.stdout.write("sweep-supervisor-state: unreadable summary\n"); return; }
  const mode = s.apply ? "apply" : "dry-run";
  process.stdout.write("sweep-supervisor-state (" + mode + ")\n");
  for (const d of s.details || []) {
    if (d.status === "candidate") process.stdout.write("  would remove " + d.records_removed + " record(s): " + d.file + "\n");
    else if (d.status === "modified") process.stdout.write("  removed " + d.records_removed + " record(s): " + d.file + "\n");
    else if (d.status === "skipped_live") process.stdout.write("  skipped (live session): " + d.file + "\n");
    else if (d.status === "skipped_recent") process.stdout.write("  skipped (updated <24h ago): " + d.file + "\n");
    else if (d.status === "unparsable") process.stdout.write("  skipped (unparsable JSON): " + d.file + "\n");
  }
  process.stdout.write("  scanned=" + s.scanned + " contaminated=" + s.files_contaminated +
    " modified=" + s.files_modified + " records_removed=" + s.records_removed +
    " emptied=" + s.files_emptied + " skipped_live=" + s.skipped_live +
    " skipped_recent=" + s.skipped_recent + " unparsable=" + s.files_skipped_unparsable + "\n");
  if (s.backup_dir) process.stdout.write("  backup: " + s.backup_dir + "\n");
  for (const e of s.errors || []) process.stdout.write("  error: " + e + "\n");
});
'

sweep_write_mode_footer
exit 0
