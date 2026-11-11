#!/usr/bin/env bash
# tests/skills/feature-1694-detect-restart-rules.sh
# Tests: skills/worktree-end/scripts/detect-restart.sh, skills/worktree-end/scripts/detect-restart-rules.js
# Tags: scope:issue-specific, TL2, test-lang-exception:e2e, worktree-end, detect-restart, rules-injection, cc-restart, fail-safe, pwsh-not-required
#
# #1694: only a PR that changes a rule loaded at session start (EXPECTED_UNCONDITIONAL of
# hooks/lib/rules-injection-policy.js) or the policy itself requires a Claude Code restart.
# The policy is read from the worktree argument ($2, the PR-side checkout), never from the
# script checkout. An unreadable policy fails safe to required; the exit stays 0 with 4 lines.
# TL3 gap: the real `gh` against a merged PR is stubbed; the real worktree-end flow is not run.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

REAL_SCRIPTS="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts"
REAL_POLICY="$SCRIPT_CHECKOUT_ROOT/hooks/lib/rules-injection-policy.js"
REAL_READER="$SCRIPT_CHECKOUT_ROOT/hooks/lib/rules-policy-reader.js"
STUB_BIN="$_ISOLATION_TMP_ROOT/stub-bin"
DATA="$_ISOLATION_TMP_ROOT/data"
mkdir -p "$STUB_BIN" "$DATA"

# Stub gh: `pr view` prints $STUB_GH_FILES; every call is logged.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view") cat "$STUB_GH_FILES" ;;
  "pr diff") cat "${STUB_GH_DIFF:-/dev/null}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# Policy bodies for the worktree / script checkout. Each carries only what the case needs.
write_policy() { # <dir> <real|test-uncond|core-only|no-decl|none>
  local f="$1/hooks/lib/rules-injection-policy.js"
  mkdir -p "$1/hooks/lib"
  case "$2" in
    real) cp "$REAL_POLICY" "$f" ;;
    test-uncond) printf 'const EXPECTED_UNCONDITIONAL = [\n  "rules/test.md",\n];\n' > "$f" ;;
    core-only) printf 'const EXPECTED_UNCONDITIONAL = [\n  "rules/core-principles.md",\n];\n' > "$f" ;;
    no-decl) printf 'const ON_DEMAND_TOKEN = "x";\n' > "$f" ;;
    empty-decl) printf 'const EXPECTED_UNCONDITIONAL = [];\n' > "$f" ;;
    none) ;;
  esac
}

# make_script_checkout <name> <sc-policy> [nohelper] — the 4 files copied at their real relative
# paths; the only place the helper's dependency closure (reader) is enumerated.
make_script_checkout() {
  local sc="$_ISOLATION_TMP_ROOT/sc-$1"
  mkdir -p "$sc/skills/worktree-end/scripts" "$sc/hooks/lib"
  cp "$REAL_SCRIPTS/detect-restart.sh" "$sc/skills/worktree-end/scripts/"
  cp "$REAL_SCRIPTS/detect-restart-skill-md.js" "$sc/skills/worktree-end/scripts/"
  [ "${3:-}" = nohelper ] || cp "$REAL_SCRIPTS/detect-restart-rules.js" "$sc/skills/worktree-end/scripts/" 2>/dev/null
  cp "$REAL_READER" "$sc/hooks/lib/"
  write_policy "$sc" "$2"
  printf '%s' "$sc"
}

make_worktree() { # <name> <policy-kind>
  local wt="$_ISOLATION_TMP_ROOT/wt-$1"
  mkdir -p "$wt"
  write_policy "$wt" "$2"
  printf '%s' "$wt"
}

SC_STD="$(make_script_checkout std real)"
SC_NOHELPER="$(make_script_checkout nohelper real nohelper)"
SC_TEST_UNCOND="$(make_script_checkout testuncond test-uncond)"
WT_REAL="$(make_worktree real real)"
WT_TEST_UNCOND="$(make_worktree testuncond test-uncond)"
WT_CORE_ONLY="$(make_worktree coreonly core-only)"
WT_NOPOLICY="$(make_worktree nopolicy none)"
WT_NODECL="$(make_worktree nodecl no-decl)"
WT_EMPTYDECL="$(make_worktree emptydecl empty-decl)"

RUN_OUT=""
RUN_RC=0
RUN_SEQ=0
# run_detect <script-checkout> <files> [worktree] — omit the worktree to call with no 2nd argument.
run_detect() {
  local sc="$1" files="$2"
  RUN_SEQ=$((RUN_SEQ + 1))
  local files_file="$DATA/files-$RUN_SEQ.txt"
  printf '%s\n' "$files" > "$files_file"
  : > "$DATA/gh-$RUN_SEQ.log"
  local args=(999)
  [ "$#" -ge 3 ] && args+=("$3")
  RUN_RC=0
  RUN_OUT="$(cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 env PATH="$STUB_BIN:$PATH" \
    STUB_GH_LOG="$DATA/gh-$RUN_SEQ.log" STUB_GH_FILES="$files_file" STUB_GH_DIFF="${DIFF_FILE:-}" \
    bash "$sc/skills/worktree-end/scripts/detect-restart.sh" "${args[@]}" 2>/dev/null)" || RUN_RC=$?
}

line_of() { printf '%s\n' "$RUN_OUT" | grep -E "^$1=" | head -1; }
check_eq() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}

RULE_REASON="cc_restart=required|rules/ unconditional rule modified in PR (loaded at session start, no paths: key)"
POLICY_REASON="cc_restart=required|rules-injection policy modified in PR (the unconditional rule set itself changed)"
UNREAD_REASON="cc_restart=required|rules-injection policy unreadable (fail-safe: restart required)"
NOT_REQ="cc_restart=not_required|"
POLICY_PATH="hooks/lib/rules-injection-policy.js"

case_begin "unconditional-rule-only" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/core-principles.md" "$WT_REAL"
check_eq "unconditional rule: exit 0" "0" "$RUN_RC"
check_eq "unconditional rule: required with the new reason" "$RULE_REASON" "$(line_of cc_restart)"
case_end

case_begin "on-demand-rule-only" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" "$WT_REAL"
check_eq "on-demand rule: exit 0" "0" "$RUN_RC"
check_eq "on-demand rule: not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "conditional-sub-rule-only" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/coding/file-split.md" "$WT_REAL"
check_eq "conditional sub-rule: not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "mixed-rules" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "$(printf 'rules/test.md\nrules/core-principles.md')" "$WT_REAL"
check_eq "on-demand + unconditional: required" "$RULE_REASON" "$(line_of cc_restart)"
case_end

case_begin "deleted-unconditional-rule" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/user-escalation.md" "$WT_REAL"
check_eq "deleted unconditional rule path (not on disk): required" "$RULE_REASON" "$(line_of cc_restart)"
case_end

case_begin "policy-change-only" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "$POLICY_PATH" "$WT_REAL"
check_eq "policy only: required with the policy reason" "$POLICY_REASON" "$(line_of cc_restart)"
case_end

case_begin "policy-change-plus-non-expanded-rule" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "$(printf '%s\nrules/test.md' "$POLICY_PATH")" "$WT_REAL"
check_eq "policy + on-demand rule: required with the policy reason" "$POLICY_REASON" "$(line_of cc_restart)"
case_end

case_begin "worktree-policy-wins" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" "$WT_TEST_UNCOND"
check_eq "PR-side policy declares test.md unconditional: required" "$RULE_REASON" "$(line_of cc_restart)"
case_end

case_begin "script-checkout-policy-ignored" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_TEST_UNCOND" "rules/test.md" "$WT_CORE_ONLY"
check_eq "script-checkout policy declares test.md unconditional but the worktree does not: not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "worktree-argument-missing" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md"
check_eq "no worktree argument: exit 0" "0" "$RUN_RC"
check_eq "no worktree argument: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

case_begin "policy-file-missing" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" "$WT_NOPOLICY"
check_eq "policy file absent: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

case_begin "policy-declaration-unparseable" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" "$WT_NODECL"
check_eq "EXPECTED_UNCONDITIONAL missing: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

case_begin "policy-declaration-empty" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" "$WT_EMPTYDECL"
check_eq "EXPECTED_UNCONDITIONAL empty: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

case_begin "claude-md-precedes-rules" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "$(printf 'CLAUDE.md\nrules/test.md')" "$WT_REAL"
check_eq "CLAUDE.md row wins over rules/" "cc_restart=required|CLAUDE.md modified in PR" "$(line_of cc_restart)"
case_end

case_begin "non-rules-path-needs-no-helper" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_NOHELPER" "bin/some-tool.js" "$WT_REAL"
check_eq "non-rules path (helper absent): exit 0" "0" "$RUN_RC"
check_eq "non-rules path (helper absent): not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "unreadable-keeps-exit-and-four-lines" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "rules/test.md" "$WT_NOPOLICY"
check_eq "unreadable: exit 0" "0" "$RUN_RC"
check_eq "unreadable: four category lines" "4" "$(printf '%s\n' "$RUN_OUT" | grep -cE '^(cc_restart|vscode_reload|installer_rerun|os_reboot)=')"
run_detect "$SC_NOHELPER" "rules/test.md" "$WT_REAL"
check_eq "helper missing: exit 0" "0" "$RUN_RC"
check_eq "helper missing: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

SETTINGS_REASON="cc_restart=required|settings.json or settings-extension.json modified in PR"
SKILL_REASON="cc_restart=required|SKILL.md added, removed or frontmatter changed"
DIFF_FM="$DATA/diff-skill-fm.txt"
printf '%s\n' 'diff --git a/skills/foo/SKILL.md b/skills/foo/SKILL.md' 'index 1111111..2222222 100644' \
  '--- a/skills/foo/SKILL.md' '+++ b/skills/foo/SKILL.md' '@@ -1,6 +1,6 @@' ' ---' ' name: foo' \
  '-user-invocable: true' '+user-invocable: false' ' description: x' ' ---' > "$DIFF_FM"

case_begin "stage-a-fallthrough" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "$(printf 'rules/test.md\nsettings.json')" "$WT_REAL"
check_eq "non-expanded rule + settings.json: falls through to the settings reason" "$SETTINGS_REASON" "$(line_of cc_restart)"
DIFF_FILE="$DIFF_FM"
run_detect "$SC_STD" "$(printf 'rules/test.md\nskills/foo/SKILL.md')" "$WT_REAL"
DIFF_FILE=""
check_eq "non-expanded rule + SKILL.md frontmatter: falls through to the SKILL.md reason" "$SKILL_REASON" "$(line_of cc_restart)"
run_detect "$SC_STD" "$(printf 'rules/core-principles.md\nsettings.json')" "$WT_REAL"
check_eq "unconditional rule + settings.json: the earlier rules row wins" "$RULE_REASON" "$(line_of cc_restart)"
case_end

# Near-miss table: name | file | want (RULE = rules reason, NOT = not_required). Every rules/ near-miss
# is absent from the real EXPECTED_UNCONDITIONAL, so not_required relies on the exact-match allowlist.
case_begin "allowlist-near-miss-table" "skills/worktree-end/scripts/detect-restart-rules.js"
while IFS='|' read -r name file want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
  run_detect "$SC_STD" "$file" "$WT_REAL"
  [ "$want" = RULE ] && want_line="$RULE_REASON" || want_line="$NOT_REQ"
  check_eq "near-miss $name ($file): $want" "$want_line" "$(line_of cc_restart)"
done <<'TABLE'
sub-dir-git         | rules/coding/git.md                       | NOT
backup-suffix       | rules/git.md.orig                         | NOT
upper-case          | rules/CORE-PRINCIPLES.md                  | NOT
test-dir-policy     | tests/hooks/lib/rules-injection-policy.js | NOT
policy-bak          | hooks/lib/rules-injection-policy.js.bak   | NOT
dot-unescaped-rule  | rules/core-principlesXmd                  | NOT
dot-unescaped-policy| hooks/lib/rules-injection-policyXjs       | NOT
exact-unconditional | rules/core-principles.md                  | RULE
TABLE
case_end

case_begin "failsafe-pair-non-rules-path" "skills/worktree-end/scripts/detect-restart.sh"
run_detect "$SC_STD" "bin/some-tool.js" "$WT_NOPOLICY"
check_eq "non-rules path + policy absent: not_required" "$NOT_REQ" "$(line_of cc_restart)"
run_detect "$SC_STD" "bin/some-tool.js"
check_eq "non-rules path + no worktree argument: not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "worktree-policy-not-executed" "skills/worktree-end/scripts/detect-restart-rules.js"
PROBE_MARKER="$DATA/policy-executed.marker"
WT_PROBE="$_ISOLATION_TMP_ROOT/wt-probe"
mkdir -p "$WT_PROBE/hooks/lib"
printf 'require("fs").writeFileSync("%s", "x");\nconst EXPECTED_UNCONDITIONAL = [\n  "rules/test.md",\n];\n' "$PROBE_MARKER" > "$WT_PROBE/hooks/lib/rules-injection-policy.js"
run_detect "$SC_STD" "rules/test.md" "$WT_PROBE"
check_eq "probe policy declares test.md unconditional: required" "$RULE_REASON" "$(line_of cc_restart)"
if [ -e "$PROBE_MARKER" ]; then fail "worktree policy is data only" "marker written: the policy was executed"; else pass "worktree policy is data only (marker absent)"; fi
case_end

case_begin "pr-filename-shell-metachar-and-space" "skills/worktree-end/scripts/detect-restart-rules.js"
INJ_MARKER="$DATA/inj.marker"
run_detect "$SC_STD" "rules/\$(touch $INJ_MARKER).md" "$WT_REAL"
check_eq "shell-metachar PR path: exit 0" "0" "$RUN_RC"
check_eq "shell-metachar PR path: not_required" "$NOT_REQ" "$(line_of cc_restart)"
if [ -e "$INJ_MARKER" ]; then fail "PR path is data only" "marker written: the path was shell-expanded"; else pass "PR path is data only (marker absent)"; fi
run_detect "$SC_STD" "rules/core principles.md" "$WT_REAL"
check_eq "space-containing PR path: not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "worktree-path-with-space" "skills/worktree-end/scripts/detect-restart-rules.js"
WT_SPACE="$_ISOLATION_TMP_ROOT/wt with space"
mkdir -p "$WT_SPACE"
write_policy "$WT_SPACE" real
run_detect "$SC_STD" "rules/core-principles.md" "$WT_SPACE"
check_eq "worktree path with space: unconditional rule required" "$RULE_REASON" "$(line_of cc_restart)"
run_detect "$SC_STD" "rules/test.md" "$WT_SPACE"
check_eq "worktree path with space: on-demand rule not_required" "$NOT_REQ" "$(line_of cc_restart)"
case_end

case_begin "worktree-argument-empty-string" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" "rules/test.md" ""
check_eq "empty-string worktree argument: exit 0" "0" "$RUN_RC"
check_eq "empty-string worktree argument: required, policy unreadable" "$UNREAD_REASON" "$(line_of cc_restart)"
case_end

case_begin "crlf-pr-path-unconditional-rule" "skills/worktree-end/scripts/detect-restart-rules.js"
run_detect "$SC_STD" $'rules/core-principles.md\r\nrules/test.md\r' "$WT_REAL"
check_eq "CRLF PR paths: unconditional rule still required" "$RULE_REASON" "$(line_of cc_restart)"
run_detect "$SC_STD" $'rules/test.md\r' "$WT_REAL"
check_eq "CRLF on-demand rule only: not_required" "$NOT_REQ" "$(line_of cc_restart)"
# Git Bash command substitution drops \r before the helper sees it, so also feed the helper directly.
HELPER="$SC_STD/skills/worktree-end/scripts/detect-restart-rules.js"
CRLF_UNCOND=$'rules/core-principles.md\r\n'
CRLF_ONDEMAND=$'rules/test.md\r\n'
check_eq "CRLF direct helper: unconditional rule -> yes" "yes" "$(printf '%s' "$CRLF_UNCOND" | node "$HELPER" "$WT_REAL")"
check_eq "CRLF direct helper: on-demand rule only -> no" "no" "$(printf '%s' "$CRLF_ONDEMAND" | node "$HELPER" "$WT_REAL")"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
