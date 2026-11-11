#!/usr/bin/env bash
# Detect post-merge action requirements and output one line per category.
# Output format: key=required_or_not_required|reason
# Categories: cc_restart, vscode_reload, installer_rerun, os_reboot
# Always exits 0 (fail-safe). On any gh failure, outputs all not_required|.
# Args: $1 = PR_NUMBER, $2 = PR-side worktree path (rules-injection policy source; missing => fail-safe required)
# reason strings are fixed sentinels (not variable filenames) — see each stage below;
# os_reboot is always not_required at this layer (env override lives in SKILL.md).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

emit_all_not_required() {
  printf 'cc_restart=not_required|\n'
  printf 'vscode_reload=not_required|\n'
  printf 'installer_rerun=not_required|\n'
  printf 'os_reboot=not_required|\n'
}

PR_NUMBER="${1:-}"
# $2 = PR-side worktree path (policy source for Stage A); normalized to mixed form for node.
WORKTREE="${2:-}"
if [[ -n "$WORKTREE" ]] && command -v cygpath >/dev/null 2>&1; then
  WORKTREE="$(cygpath -m "$WORKTREE" 2>/dev/null || printf '%s' "$WORKTREE")"
fi
if [[ -z "$PR_NUMBER" ]]; then
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

# skill_md_changed — yes when a SKILL.md in the PR is added, removed or has its frontmatter
# changed (#1076). gh pr diff works after squash-merge; captured first to avoid SIGPIPE.
skill_md_changed() {
  local pr_diff verdict
  pr_diff="$(gh pr diff "$PR_NUMBER" 2>/dev/null)" || return 1
  verdict="$(printf '%s\n' "$pr_diff" | node "$SCRIPT_DIR/detect-restart-skill-md.js" 2>/dev/null)" || return 1
  [[ "$verdict" == "yes" ]]
}

# unconditional_rule_verdict — rules/ files in the PR that Claude Code expands at session start.
# Definition source: EXPECTED_UNCONDITIONAL in the PR-side worktree's rules-injection-policy.js,
# read as data by detect-restart-rules.js (#1694). Sets UR_UNREADABLE=1 when the policy cannot be
# read (or node fails): the caller then requires a restart (fail-safe). Returns 0 only for "yes".
UR_UNREADABLE=0
unconditional_rule_verdict() {
  local verdict
  verdict="$(printf '%s\n' "$CC_FILES" | grep -E '^rules/.+$' | node "$SCRIPT_DIR/detect-restart-rules.js" "$WORKTREE" 2>/dev/null)" || verdict="unreadable"
  case "$verdict" in
    yes) return 0 ;;
    no) return 1 ;;
    *) UR_UNREADABLE=1; return 1 ;;
  esac
}

# Stage A: cc_restart — classification table <pattern> TAB <check> TAB <fixed reason>;
# the first row whose pattern matches (and whose check passes) wins.
CC_RESTART_TABLE=(
  $'^(CLAUDE\\.md|CLAUDE\\.local\\.md)$\tnone\tCLAUDE.md modified in PR'
  $'^rules/.+$\tunconditional_rule\trules/ unconditional rule modified in PR (loaded at session start, no paths: key)'
  $'^hooks/lib/rules-injection-policy\\.js$\tnone\trules-injection policy modified in PR (the unconditional rule set itself changed)'
  $'^settings(-extension)?\\.json$\tnone\tsettings.json or settings-extension.json modified in PR'
  $'(^|/)SKILL\\.md$\tskill_md\tSKILL.md added, removed or frontmatter changed'
)
CC_RESTART_LINE="cc_restart=not_required|"
for row in "${CC_RESTART_TABLE[@]}"; do
  IFS=$'\t' read -r cc_pattern cc_check cc_reason <<< "$row"
  printf '%s\n' "$CC_FILES" | grep -qE "$cc_pattern" || continue
  if [[ "$cc_check" == "skill_md" ]] && ! skill_md_changed; then
    continue
  fi
  if [[ "$cc_check" == "unconditional_rule" ]] && ! unconditional_rule_verdict; then
    if (( UR_UNREADABLE )); then
      CC_RESTART_LINE="cc_restart=required|rules-injection policy unreadable (fail-safe: restart required)"
      break
    fi
    continue
  fi
  CC_RESTART_LINE="cc_restart=required|$cc_reason"
  break
done

# Stage B: vscode_reload
# Detect any keybindings.json (any path) OR .vscode/{extensions,settings}.json
VSCODE_LINE="vscode_reload=not_required|"
if printf '%s\n' "$CC_FILES" | grep -qE '(^|/)keybindings\.json$'; then
  VSCODE_LINE="vscode_reload=required|keybindings.json modified"
elif printf '%s\n' "$CC_FILES" | grep -qE '^\.vscode/(extensions|settings)\.json$'; then
  VSCODE_LINE="vscode_reload=required|vscode settings modified"
fi

# declared_source_changed — any path in column 2 of install/deployed-sources.txt (required and
# optional alike) is in the PR (#2303). An unreadable declaration skips only this row.
declared_source_changed() {
  local decl="$SCRIPT_CHECKOUT_ROOT/install/deployed-sources.txt" role rel _kind
  [[ -f "$decl" && -r "$decl" ]] || return 1
  while read -r role rel _kind; do
    [[ -z "$role" || "$role" == \#* || -z "$rel" ]] && continue
    printf '%s\n' "$CC_FILES" | grep -qxF -- "${rel%$'\r'}" && return 0
  done < "$decl"
  return 1
}

# Stage C: installer_rerun
# Priority: install.ps1 > install.sh > install/ subtree > declared deployed source
INSTALLER_LINE="installer_rerun=not_required|"
if printf '%s\n' "$CC_FILES" | grep -qE '(^|/)install\.ps1$'; then
  INSTALLER_LINE="installer_rerun=required|install.ps1 modified in PR"
elif printf '%s\n' "$CC_FILES" | grep -qE '(^|/)install\.sh$'; then
  INSTALLER_LINE="installer_rerun=required|install.sh modified in PR"
elif printf '%s\n' "$CC_FILES" | grep -qE '^install/'; then
  INSTALLER_LINE="installer_rerun=required|installer script modified in PR"
elif declared_source_changed; then
  INSTALLER_LINE="installer_rerun=required|installer-deployed source modified in PR"
fi

# Stage D: os_reboot
# os_reboot: env override is SKILL.md's responsibility (Option B)
OS_REBOOT_LINE="os_reboot=not_required|"

printf '%s\n' "$CC_RESTART_LINE"
printf '%s\n' "$VSCODE_LINE"
printf '%s\n' "$INSTALLER_LINE"
printf '%s\n' "$OS_REBOOT_LINE"
