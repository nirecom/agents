#!/usr/bin/env bash
# tests/skills/feature-2303-1076-detect-restart.sh
# Tests: skills/worktree-end/scripts/detect-restart.sh, install/deployed-sources.txt
# Tags: scope:issue-specific, TL2, worktree-end, detect-restart, post-merge, settings, skill-md, deployed-sources, pwsh-not-required
#
# #2303: any settings(-extension).json change → cc_restart and installer_rerun both required; Stage C
# reads install/deployed-sources.txt. #1076: a SKILL.md add/delete/frontmatter change → cc_restart
# required (gh pr diff fetched only when a SKILL.md is in the PR). Always exit 0 (fail-safe).
# TL3 gap: the real `gh` against a merged PR is stubbed; checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

REAL_SCRIPTS="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts"
STUB_BIN="$_ISOLATION_TMP_ROOT/stub-bin"
DATA="$_ISOLATION_TMP_ROOT/data"
mkdir -p "$STUB_BIN" "$DATA"

# Stub gh: `pr view` prints $STUB_GH_FILES, `pr diff` prints $STUB_GH_DIFF; every call is logged.
# STUB_GH_FAIL=view|diff makes that subcommand exit 1.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view") [ "${STUB_GH_FAIL:-}" = view ] && exit 1; cat "$STUB_GH_FILES" ;;
  "pr diff") [ "${STUB_GH_FAIL:-}" = diff ] && exit 1; cat "$STUB_GH_DIFF" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# fixture_tree <name> <declaration-file|none|dir> — a checkout copy holding detect-restart.sh (and
# the SKILL.md helper when present) at its real relative path; the declaration is copied, absent, or a dir.
fixture_tree() {
  local fx="$_ISOLATION_TMP_ROOT/fx-$1"
  mkdir -p "$fx/skills/worktree-end/scripts" "$fx/install"
  cp "$REAL_SCRIPTS/detect-restart.sh" "$fx/skills/worktree-end/scripts/"
  [ -f "$REAL_SCRIPTS/detect-restart-skill-md.js" ] && cp "$REAL_SCRIPTS/detect-restart-skill-md.js" "$fx/skills/worktree-end/scripts/"
  case "$2" in
    none) ;;
    dir) mkdir -p "$fx/install/deployed-sources.txt" ;;
    *) cp "$2" "$fx/install/deployed-sources.txt" ;;
  esac
  printf '%s' "$fx"
}

DECL_STD="$DATA/decl-std.txt"
cat > "$DECL_STD" <<'DECL'
# fixture declaration
settings-base settings.json required
settings-extension settings-extension.json optional
DECL

DECL_EXTRA="$DATA/decl-extra.txt"
cat > "$DECL_EXTRA" <<'DECL'
# legacy legacy/old.json required
settings-base settings.json required
settings-extension settings-extension.json optional
custom-role extra/deployed.conf optional
DECL

DECL_CRLF="$DATA/decl-crlf.txt"
printf '# fixture declaration\r\nsettings-base settings.json required\r\nsettings-extension settings-extension.json optional\r\n' > "$DECL_CRLF"

FX_STD="$(fixture_tree std "$DECL_STD")"
FX_CRLF="$(fixture_tree crlf "$DECL_CRLF")"
FX_EXTRA="$(fixture_tree extra "$DECL_EXTRA")"
FX_NODECL="$(fixture_tree nodecl none)"
FX_DIRDECL="$(fixture_tree dirdecl dir)"

# Diff fixtures (heredocs so no marker-looking text sits in a quoted string).
DIFF_PERMS="$DATA/diff-perms.txt"
cat > "$DIFF_PERMS" <<'DIFF'
diff --git a/settings.json b/settings.json
index 1111111..2222222 100644
--- a/settings.json
+++ b/settings.json
@@ -10,6 +10,7 @@
       "allow": [
         "Bash(git status)",
+        "Bash(git log *)",
         "Bash(ls *)"
       ],
DIFF
DIFF_SKILL_NEW="$DATA/diff-skill-new.txt"
cat > "$DIFF_SKILL_NEW" <<'DIFF'
diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/skills/foo/SKILL.md
@@ -0,0 +1,4 @@
+---
+name: foo
+---
+body
DIFF
DIFF_SKILL_DEL="$DATA/diff-skill-del.txt"
cat > "$DIFF_SKILL_DEL" <<'DIFF'
diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md
deleted file mode 100644
index 1111111..0000000
--- a/skills/foo/SKILL.md
+++ /dev/null
@@ -1,4 +0,0 @@
----
-name: foo
----
-body
DIFF
DIFF_SKILL_FM="$DATA/diff-skill-fm.txt"
cat > "$DIFF_SKILL_FM" <<'DIFF'
diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md
index 1111111..2222222 100644
--- a/skills/foo/SKILL.md
+++ b/skills/foo/SKILL.md
@@ -1,6 +1,6 @@
 ---
 name: foo
-user-invocable: true
+user-invocable: false
 description: x
 ---

DIFF
DIFF_SKILL_BODY="$DATA/diff-skill-body.txt"
cat > "$DIFF_SKILL_BODY" <<'DIFF'
diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md
index 1111111..2222222 100644
--- a/skills/foo/SKILL.md
+++ b/skills/foo/SKILL.md
@@ -20,7 +20,7 @@
 context a
 context b
 context c
-old step
+new step
 context d
 context e
DIFF
EMPTY="$DATA/empty.txt"
: > "$EMPTY"

RUN_OUT=""
RUN_RC=0
GH_LOG=""
RUN_SEQ=0
# run_detect <fixture-root> <files-list> <diff-file> [fail-mode] — runs the fixture's detect-restart.sh
# with the stub gh first on PATH; sets RUN_OUT, RUN_RC, GH_LOG (log path).
run_detect() {
  local fx="$1" files="$2" diff="$3" failmode="${4:-}"
  RUN_SEQ=$((RUN_SEQ + 1))
  local files_file="$DATA/files-$RUN_SEQ.txt"
  GH_LOG="$DATA/gh-$RUN_SEQ.log"
  printf '%s\n' "$files" > "$files_file"
  : > "$GH_LOG"
  RUN_RC=0
  RUN_OUT="$(cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 env PATH="$STUB_BIN:$PATH" \
    STUB_GH_LOG="$GH_LOG" STUB_GH_FILES="$files_file" STUB_GH_DIFF="$diff" STUB_GH_FAIL="$failmode" \
    bash "$fx/skills/worktree-end/scripts/detect-restart.sh" 999 2>/dev/null)" || RUN_RC=$?
}

# line_of <key> — the output line for one category.
line_of() { printf '%s\n' "$RUN_OUT" | grep -E "^$1=" | head -1; }

check_eq() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}
check_prefix() { # <name> <prefix> <got>
  case "$3" in "$2"*) pass "$1" ;; *) fail "$1" "want prefix=$(printf '%q' "$2") got=$(printf '%q' "$3")" ;; esac
}
diff_calls() { grep -c '^pr diff' "$GH_LOG" 2>/dev/null || true; }

INSTALLER_DECL_REASON="installer_rerun=required|installer-deployed source modified in PR"
SKILL_REASON="cc_restart=required|SKILL.md added, removed or frontmatter changed"

case_begin "settings-json-permissions-only" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "settings.json" "$DIFF_PERMS"
check_eq "settings.json: exit 0" "0" "$RUN_RC"
check_prefix "settings.json permissions-only: cc_restart required" "cc_restart=required|" "$(line_of cc_restart)"
check_eq "settings.json permissions-only: installer_rerun required by declaration" "$INSTALLER_DECL_REASON" "$(line_of installer_rerun)"
case_end

case_begin "settings-extension-json-change" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "settings-extension.json" "$DIFF_PERMS"
check_eq "settings-extension.json: exit 0" "0" "$RUN_RC"
check_prefix "settings-extension.json: cc_restart required" "cc_restart=required|" "$(line_of cc_restart)"
check_eq "settings-extension.json: installer_rerun required (optional entry still detected)" "$INSTALLER_DECL_REASON" "$(line_of installer_rerun)"
case_end

case_begin "real-declaration-settings-json" "install/deployed-sources.txt"
run_detect "$SCRIPT_CHECKOUT_ROOT" "settings.json" "$DIFF_PERMS"
check_eq "real checkout declaration: settings.json → installer_rerun required" "$INSTALLER_DECL_REASON" "$(line_of installer_rerun)"
case_end

case_begin "declared-extra-entry-detected" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_EXTRA" "extra/deployed.conf" "$EMPTY"
check_eq "extra declared path: installer_rerun required" "$INSTALLER_DECL_REASON" "$(line_of installer_rerun)"
check_eq "extra declared path: cc_restart not_required" "cc_restart=not_required|" "$(line_of cc_restart)"
run_detect "$FX_EXTRA" "legacy/old.json" "$EMPTY"
check_eq "commented-out declaration line is not an entry" "installer_rerun=not_required|" "$(line_of installer_rerun)"
case_end

case_begin "crlf-declaration-settings-json" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_CRLF" "settings.json" "$DIFF_PERMS"
check_eq "CRLF declaration: exit 0" "0" "$RUN_RC"
check_eq "CRLF declaration: settings.json → installer_rerun required" "$INSTALLER_DECL_REASON" "$(line_of installer_rerun)"
case_end

case_begin "skill-md-added" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "skills/foo/SKILL.md" "$DIFF_SKILL_NEW"
check_eq "SKILL.md added: cc_restart required" "$SKILL_REASON" "$(line_of cc_restart)"
check_eq "SKILL.md added: gh pr diff fetched once" "1" "$(diff_calls)"
case_end

case_begin "skill-md-deleted" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "skills/foo/SKILL.md" "$DIFF_SKILL_DEL"
check_eq "SKILL.md deleted: cc_restart required" "$SKILL_REASON" "$(line_of cc_restart)"
case_end

case_begin "skill-md-frontmatter-changed" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "skills/foo/SKILL.md" "$DIFF_SKILL_FM"
check_eq "SKILL.md frontmatter changed: cc_restart required" "$SKILL_REASON" "$(line_of cc_restart)"
check_eq "SKILL.md frontmatter changed: gh pr diff fetched once" "1" "$(diff_calls)"
case_end

case_begin "skill-md-body-only" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "skills/foo/SKILL.md" "$DIFF_SKILL_BODY"
check_eq "SKILL.md body-only: exit 0" "0" "$RUN_RC"
check_eq "SKILL.md body-only: cc_restart not_required" "cc_restart=not_required|" "$(line_of cc_restart)"
case_end

case_begin "no-skill-md-no-diff-call" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "bin/some-tool.js" "$DIFF_SKILL_NEW"
check_eq "unrelated file: gh pr diff not called" "0" "$(diff_calls)"
check_eq "unrelated file: cc_restart not_required" "cc_restart=not_required|" "$(line_of cc_restart)"
check_eq "unrelated file: installer_rerun not_required" "installer_rerun=not_required|" "$(line_of installer_rerun)"
check_eq "unrelated file: vscode_reload not_required" "vscode_reload=not_required|" "$(line_of vscode_reload)"
case_end

case_begin "existing-rows-still-required" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "CLAUDE.md" "$EMPTY"
check_eq "CLAUDE.md row unchanged" "cc_restart=required|CLAUDE.md modified in PR" "$(line_of cc_restart)"
run_detect "$FX_STD" "rules/workflow-off.md" "$EMPTY"
check_eq "rules/ row unchanged" "cc_restart=required|rules/ modified in PR (rules/ content loads into the effective CLAUDE.md ruleset)" "$(line_of cc_restart)"
run_detect "$FX_STD" "install.sh" "$EMPTY"
check_eq "install.sh row unchanged" "installer_rerun=required|install.sh modified in PR" "$(line_of installer_rerun)"
run_detect "$FX_STD" "install/lib/settings-assembly.js" "$EMPTY"
check_eq "install/ row unchanged" "installer_rerun=required|installer script modified in PR" "$(line_of installer_rerun)"
case_end

case_begin "declaration-missing-fail-safe" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_NODECL" "$(printf 'settings.json\nkeybindings.json')" "$DIFF_PERMS"
check_eq "no declaration: exit 0" "0" "$RUN_RC"
check_prefix "no declaration: cc_restart still judged" "cc_restart=required|" "$(line_of cc_restart)"
check_eq "no declaration: vscode_reload still judged" "vscode_reload=required|keybindings.json modified" "$(line_of vscode_reload)"
check_eq "no declaration: declaration row skipped" "installer_rerun=not_required|" "$(line_of installer_rerun)"
run_detect "$FX_NODECL" "install.sh" "$EMPTY"
check_eq "no declaration: installer body rows still judged" "installer_rerun=required|install.sh modified in PR" "$(line_of installer_rerun)"
run_detect "$FX_DIRDECL" "settings.json" "$DIFF_PERMS"
check_eq "unreadable declaration (a directory): exit 0" "0" "$RUN_RC"
check_eq "unreadable declaration: declaration row skipped" "installer_rerun=not_required|" "$(line_of installer_rerun)"
case_end

case_begin "gh-failure-fail-safe" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "settings.json" "$DIFF_PERMS" view
check_eq "gh pr view failure: exit 0" "0" "$RUN_RC"
check_eq "gh pr view failure: four not_required lines" "4" "$(printf '%s\n' "$RUN_OUT" | grep -cE '^(cc_restart|vscode_reload|installer_rerun|os_reboot)=not_required\|$')"
run_detect "$FX_STD" "$(printf 'skills/foo/SKILL.md\nkeybindings.json')" "$DIFF_SKILL_NEW" diff
check_eq "gh pr diff failure: exit 0" "0" "$RUN_RC"
check_eq "gh pr diff failure: SKILL.md row fails safe" "cc_restart=not_required|" "$(line_of cc_restart)"
check_eq "gh pr diff failure: other rows still judged" "vscode_reload=required|keybindings.json modified" "$(line_of vscode_reload)"
case_end

SETTINGS_REASON="cc_restart=required|settings.json or settings-extension.json modified in PR"

# Rows: <single PR path> TAB <diff fixture> TAB <category key> TAB <expected line>.
SINGLE_PATH_TABLE=(
  $'CLAUDE.local.md\t'"$EMPTY"$'\tcc_restart\tcc_restart=required|CLAUDE.md modified in PR'
  $'settings.json\t'"$DIFF_PERMS"$'\tcc_restart\t'"$SETTINGS_REASON"
  $'settings-extension.json\t'"$DIFF_PERMS"$'\tcc_restart\t'"$SETTINGS_REASON"
  $'skills/foo/SKILL.md\t'"$DIFF_SKILL_FM"$'\tcc_restart\t'"$SKILL_REASON"
  $'.vscode/settings.json\t'"$EMPTY"$'\tvscode_reload\tvscode_reload=required|vscode settings modified'
  $'install.ps1\t'"$EMPTY"$'\tinstaller_rerun\tinstaller_rerun=required|install.ps1 modified in PR'
  $'sub/install.sh\t'"$EMPTY"$'\tinstaller_rerun\tinstaller_rerun=required|install.sh modified in PR'
  $'install/lib/x.js\t'"$EMPTY"$'\tinstaller_rerun\tinstaller_rerun=required|installer script modified in PR'
  $'docs/unrelated.md\t'"$EMPTY"$'\tcc_restart\tcc_restart=not_required|'
  $'docs/unrelated.md\t'"$EMPTY"$'\tinstaller_rerun\tinstaller_rerun=not_required|'
)

case_begin "single-path-reason-table" "skills/worktree-end/scripts/detect-restart.sh"
for row in "${SINGLE_PATH_TABLE[@]}"; do
  IFS=$'\t' read -r t_path t_diff t_key t_want <<< "$row"
  run_detect "$FX_STD" "$t_path" "$t_diff"
  check_eq "table $t_path: exit 0" "0" "$RUN_RC"
  check_eq "table $t_path: $t_key line" "$t_want" "$(line_of "$t_key")"
done
case_end

case_begin "precedence-install-ps1-and-settings" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "$(printf 'settings.json\ninstall.ps1')" "$DIFF_PERMS"
check_eq "install.ps1 + settings.json: install.ps1 wins installer_rerun over the declaration" "installer_rerun=required|install.ps1 modified in PR" "$(line_of installer_rerun)"
check_eq "install.ps1 + settings.json: cc_restart by settings" "$SETTINGS_REASON" "$(line_of cc_restart)"
case_end

case_begin "precedence-settings-before-skill-md" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$FX_STD" "$(printf 'skills/foo/SKILL.md\nsettings.json')" "$DIFF_SKILL_FM"
check_eq "settings.json + SKILL.md: cc_restart by settings" "$SETTINGS_REASON" "$(line_of cc_restart)"
check_eq "settings.json + SKILL.md: gh pr diff not called" "0" "$(diff_calls)"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
