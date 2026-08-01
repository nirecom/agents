#!/usr/bin/env bash
#
# bin/lib/sweep-write-mode.sh
#
# SSOT for the write-mode semantics shared by the /sweep family
# (sweep-branches / sweep-plans / sweep-worktrees / audit-tests /
# audit-tests-common / sweep-issues).
#
# Convention (matches bin/vscode-cc-repair/cli.js:31):
#   no flag    → production run: writes / deletes
#   --dry-run  → classify and report only; write nothing
#   --apply    → accepted, backward-compatible synonym of "no flag"
#
# What is shared here is the SEMANTICS, not the argv parser: the sweep-*.sh
# scripts use a trailing `shift` loop while the audit-tests*.sh scripts use
# per-arm `shift N`. Each caller keeps its own grammar and calls the setters
# from its own case arms.
#
# Source-only; not executable.

# Apply-by-default. Call once before parsing argv.
sweep_write_mode_init() {
  APPLY=1
  DRY_RUN=0
}

# --dry-run arm.
sweep_write_mode_dry_run() {
  APPLY=0
  DRY_RUN=1
}

# --apply arm (backward compatible; same state as the flagless default).
sweep_write_mode_apply() {
  APPLY=1
  DRY_RUN=0
}

# The two usage lines every member prints, in one wording.
sweep_write_mode_usage_lines() {
  printf '  --dry-run             Classify and report only; write nothing.\n'
  printf '  --apply               Explicit apply (default; kept for compatibility).\n'
}

# Trailing summary note. Silent unless the run was a dry run.
sweep_write_mode_footer() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  (dry-run; nothing was written — omit --dry-run to apply)\n'
  fi
}
