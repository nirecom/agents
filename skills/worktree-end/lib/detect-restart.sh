#!/usr/bin/env bash
# Detect post-merge action requirements and output one line per category.
# Output format: key=required_or_not_required|reason
# Categories: cc_restart, vscode_reload, installer_rerun, os_reboot
# Always exits 0 (fail-safe). On any gh failure, outputs all not_required|.
# Args: $1 = PR_NUMBER
# Env: AGENTS_CONFIG_DIR (empty → all not_required|)
#
# reason strings are fixed sentinels (not variable filenames):
#   cc_restart:       CLAUDE.md modified in PR | settings.json model field changed
#   vscode_reload:    keybindings.json modified | vscode settings modified
#   installer_rerun:  install.ps1 modified in PR | install.sh modified in PR | installer script modified in PR
#   os_reboot:        (always not_required at lib layer; env override in SKILL.md)
set -euo pipefail

emit_all_not_required() {
  printf 'cc_restart=not_required|\n'
  printf 'vscode_reload=not_required|\n'
  printf 'installer_rerun=not_required|\n'
  printf 'os_reboot=not_required|\n'
}

PR_NUMBER="${1:-}"
if [[ -z "$PR_NUMBER" ]] || [[ -z "${AGENTS_CONFIG_DIR:-}" ]]; then
  emit_all_not_required
  exit 0
fi

# Single gh API call shared by stages A/B/C.
# gh pr view --json files fetches via GitHub API and is independent of local
# branch state — squash-merge does not break it.
CC_FILES="$(gh pr view "$PR_NUMBER" --json files --jq '.files[].path' 2>/dev/null || true)"

if [[ -z "$CC_FILES" ]]; then
  emit_all_not_required
  exit 0
fi

# Stage A: cc_restart
# Top-level CLAUDE*.md or anything under rules/ → unconditional required.
CC_RESTART_LINE="cc_restart=not_required|"
if printf '%s\n' "$CC_FILES" | grep -qE '^(CLAUDE\.md|CLAUDE\.local\.md|rules/.+)$'; then
  CC_RESTART_LINE="cc_restart=required|CLAUDE.md modified in PR"
elif printf '%s\n' "$CC_FILES" | grep -qE '^settings(-extension)?\.json$'; then
  # gh pr diff retrieves the diff via GitHub API; works after squash-merge.
  # Capture to variable first to avoid grep -q early-exit triggering SIGPIPE on
  # gh pr diff under set -o pipefail.
  CC_DIFF="$(gh pr diff "$PR_NUMBER" 2>/dev/null || true)"
  if printf '%s\n' "$CC_DIFF" | grep -qE '^[+-][[:space:]]*"(model|outputStyle)"[[:space:]]*:'; then
    CC_RESTART_LINE="cc_restart=required|settings.json model field changed"
  fi
fi

# Stage B: vscode_reload
# Detect any keybindings.json (any path) OR .vscode/{extensions,settings}.json
VSCODE_LINE="vscode_reload=not_required|"
if printf '%s\n' "$CC_FILES" | grep -qE '(^|/)keybindings\.json$'; then
  VSCODE_LINE="vscode_reload=required|keybindings.json modified"
elif printf '%s\n' "$CC_FILES" | grep -qE '^\.vscode/(extensions|settings)\.json$'; then
  VSCODE_LINE="vscode_reload=required|vscode settings modified"
fi

# Stage C: installer_rerun
# Priority: install.ps1 > install.sh > install/ subtree
INSTALLER_LINE="installer_rerun=not_required|"
if printf '%s\n' "$CC_FILES" | grep -qE '(^|/)install\.ps1$'; then
  INSTALLER_LINE="installer_rerun=required|install.ps1 modified in PR"
elif printf '%s\n' "$CC_FILES" | grep -qE '(^|/)install\.sh$'; then
  INSTALLER_LINE="installer_rerun=required|install.sh modified in PR"
elif printf '%s\n' "$CC_FILES" | grep -qE '^install/'; then
  INSTALLER_LINE="installer_rerun=required|installer script modified in PR"
fi

# Stage D: os_reboot
# os_reboot: env override is SKILL.md's responsibility (Option B)
OS_REBOOT_LINE="os_reboot=not_required|"

printf '%s\n' "$CC_RESTART_LINE"
printf '%s\n' "$VSCODE_LINE"
printf '%s\n' "$INSTALLER_LINE"
printf '%s\n' "$OS_REBOOT_LINE"
