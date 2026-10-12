#!/usr/bin/env bash
# bin/lib/sweep-write-mode.sh — SSOT for the /sweep family write-mode SEMANTICS (not the argv parser;
# each caller calls the setters from its own case arms). Source-only; not executable.
# Convention (matches bin/vscode-cc-repair/cli.js:31): no flag → production run (writes / deletes);
#   --dry-run → classify and report only; --apply → backward-compatible synonym of "no flag".
# Named exception (sweep-plans): the flagless write scope is only `non-plan` retention-class files;
#   `plan` / `user-requested` files need --include-plan-and-user-requested plus the skill's approval
#   gate, and --apply never widens it (docs/architecture/claude-code/state-dirs.md, Cleanup).

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
