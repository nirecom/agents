#!/usr/bin/env bash
# tests/bin/feature-1340-issue-setup/run-issue-setup-subgroup.sh
# Tests: skills/migrate-tracker/scripts/run-issue-setup.sh, bin/detect-forge-type
# Tags: TL2, migrate-tracker, run-issue-setup, gitlab, forge, scope:issue-specific, test-lang-exception:e2e
# Issue #2960: run-issue-setup.sh takes a GitLab group/subgroup/project --repo when --root's origin
# is GitLab (host judged by the real bin/detect-forge-type), passes it to glab unchanged and matches
# it against the origin path; a path of 3 or more segments on any other host (or without --root)
# exits 2 naming --root on a GitLab checkout; '.', '..', empty segments and newlines are refused
# before any forge call. Contract: the #2960 detail plan S5 / S6 / S10.
# TL3 gap: whether a real glab accepts a subgroup --repo; here glab is a mock that logs its argv.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
. "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
set -u

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE HIA_ROOT
unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME
mkdir -p "$TMPBASE/stub-agents"
export AGENTS_MAIN_ROOT="$TMPBASE/stub-agents"

RIS_REL="skills/migrate-tracker/scripts/run-issue-setup.sh"
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

# GL_BIN: glab mock (logs argv to glab.log, exit 0) and gh stub (logs to forge.log, exit 97).
# NO_BIN: both CLIs as stubs logging to forge.log, for the cases that must reach no forge.
GL_BIN="$TMPBASE/gitlab-bin"
NO_BIN="$TMPBASE/no-forge-bin"
mkdir -p "$GL_BIN" "$NO_BIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/glab.log"\nexit 0\n' "$TMPBASE" >"$GL_BIN/glab"
for tool in gh glab; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"%s/forge.log"\nexit 97\n' "$tool" "$TMPBASE" >"$NO_BIN/$tool"
done
cp "$NO_BIN/gh" "$GL_BIN/gh"
chmod +x "$GL_BIN/glab" "$GL_BIN/gh" "$NO_BIN/gh" "$NO_BIN/glab"
reset_logs() { rm -f "$TMPBASE/glab.log" "$TMPBASE/forge.log"; }
no_forge() { [ ! -s "$TMPBASE/forge.log" ] && [ ! -s "$TMPBASE/glab.log" ]; }

# A fake checkout with the real bin/ (detect-forge-type included), hooks/ and the migrate-tracker
# skill, and a labels.yml of two entries so the labels step calls glab once per entry.
FAKE="$TMPBASE/fake-checkout"
mkdir -p "$FAKE/skills" "$FAKE/.github"
cp -R "$__LIB_SCRIPT_CHECKOUT_ROOT/bin" "$__LIB_SCRIPT_CHECKOUT_ROOT/hooks" "$FAKE/"
cp -R "$__LIB_SCRIPT_CHECKOUT_ROOT/skills/migrate-tracker" "$FAKE/skills/"
printf -- '- name: "type:task"\n  color: "0e8a16"\n  description: "task"\n- name: "status:migrated"\n  color: "cccccc"\n  description: "migrated"\n' >"$FAKE/.github/labels.yml"
RIS="$FAKE/$RIS_REL"

fx_repo() { # fx_repo <name> <origin>
  local d="$TMPBASE/repos/$1"
  mkdir -p "$d"
  harness_git_init "$d"
  git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}
R_GL="$(fx_repo gitlab-subgroup git@gitlab.com:grp/sub/proj.git)"
R_GL4="$(fx_repo gitlab-deep https://gitlab.com/grp/a/b/proj.git)"
R_GH="$(fx_repo github git@github.com:o/r.git)"
R_OTHER="$(fx_repo other-host https://git.example.org/grp/sub/proj.git)"
# ris <bin dir> <args...> — run-issue-setup.sh from a neutral cwd; stdout to out, stderr to err.
ris() {
  local bin="$1"
  shift
  (cd "$TMPBASE" && PATH="$bin:$PATH" bash "$RIS" "$@") >"$TMPBASE/out" 2>"$TMPBASE/err"
}
SEG_MSG="--root on a GitLab checkout"

case_begin "RS-gitlab-subgroup-accept" "skills/migrate-tracker/scripts/run-issue-setup.sh"
reset_logs
ris "$NO_BIN" --step labels --repo grp/sub/proj --root "$R_GL" --dry-run; rc=$?
check "subgroup labels --dry-run: exit 0 and names grp/sub/proj on gitlab" '[ "$rc" -eq 0 ] && grep -qF "grp/sub/proj (gitlab)" "$TMPBASE/out"' "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
check "subgroup labels --dry-run: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" "$TMPBASE/glab.log" 2>/dev/null)"
reset_logs
ris "$GL_BIN" --step labels --repo grp/sub/proj --root "$R_GL"; rc=$?
n_create="$(grep -c '^label create' "$TMPBASE/glab.log" 2>/dev/null)"
n_repo="$(grep -c '^label create --repo grp/sub/proj ' "$TMPBASE/glab.log" 2>/dev/null)"
check "subgroup labels: exit 0 with one glab label create per labels.yml entry" '[ "$rc" -eq 0 ] && [ "${n_create:-0}" -eq 2 ]' "rc=$rc glab=[$(cat "$TMPBASE/glab.log" 2>/dev/null)] err=[$(cat "$TMPBASE/err")]"
check "subgroup labels: every label create passes --repo grp/sub/proj unchanged" '[ "${n_repo:-0}" -eq 2 ]' "glab=[$(cat "$TMPBASE/glab.log" 2>/dev/null)]"
check "subgroup labels: gh is never started" '[ ! -s "$TMPBASE/forge.log" ]' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"
reset_logs
ris "$NO_BIN" --step labels --repo grp/a/b/proj --root "$R_GL4" --dry-run; rc=$?
check "4-segment path on gitlab --dry-run: exit 0" '[ "$rc" -eq 0 ] && grep -qF "grp/a/b/proj (gitlab)" "$TMPBASE/out"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
case_end

case_begin "RS-subgroup-root-match" "skills/migrate-tracker/scripts/run-issue-setup.sh"
reset_logs
ris "$NO_BIN" --step record-done --repo grp/sub/proj --root "$R_GL" --dry-run; rc=$?
check "subgroup record-done --dry-run: --root's origin path matches (rc 0)" '[ "$rc" -eq 0 ] && grep -q "would set migrate.tracker done" "$TMPBASE/out"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
ris "$NO_BIN" --step record-done --repo GRP/Sub/Proj --root "$R_GL" --dry-run; rc=$?
check "subgroup record-done --dry-run: the match ignores case" '[ "$rc" -eq 0 ]' "rc=$rc err=[$(cat "$TMPBASE/err")]"
ris "$NO_BIN" --step record-done --repo grp/other/proj --root "$R_GL" --dry-run; rc=$?
check "subgroup record-done --dry-run: another subgroup path is the origin mismatch (rc 2)" '[ "$rc" -eq 2 ] && grep -q "^Error: --root origin is" "$TMPBASE/err"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
check "subgroup record-done --dry-run: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" "$TMPBASE/glab.log" 2>/dev/null)"
case_end

case_begin "RS-subgroup-board-encoding" "skills/migrate-tracker/scripts/run-issue-setup.sh"
# API_BIN: a glab mock for the board steps; it logs argv and answers boards / labels / lists JSON.
API_BIN="$TMPBASE/gitlab-api-bin"
mkdir -p "$API_BIN"
cat >"$API_BIN/glab" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GLAB_API_LOG"
case "$*" in
  *"/labels?"*) echo '[{"id":11,"name":"status:todo"}]' ;;
  *"/lists"*) echo '[{"label":{"id":11}}]' ;;
  *"/boards"*) echo '[{"id":7}]' ;;
esac
exit 0
MOCK
cp "$NO_BIN/gh" "$API_BIN/gh"
chmod +x "$API_BIN/glab" "$API_BIN/gh"
export GLAB_API_LOG="$TMPBASE/glab-api.log"
ENC="grp%2Fsub%2Fproj"
rm -f "$GLAB_API_LOG"
ris "$API_BIN" --step check-project --repo grp/sub/proj --root "$R_GL"; rc=$?
check "subgroup check-project: exit 0 against a complete board" '[ "$rc" -eq 0 ]' "rc=$rc err=[$(cat "$TMPBASE/err")] log=[$(cat "$GLAB_API_LOG" 2>/dev/null)]"
check "subgroup check-project: glab api gets the project path as $ENC" 'grep -qF "api projects/$ENC/boards" "$GLAB_API_LOG" && ! grep -q "projects/grp/sub" "$GLAB_API_LOG"' "log=[$(cat "$GLAB_API_LOG" 2>/dev/null)]"
rm -f "$GLAB_API_LOG"
ris "$API_BIN" --step ensure-project --repo grp/sub/proj --root "$R_GL"; rc=$?
check "subgroup ensure-project: exit 0 reusing the existing board" '[ "$rc" -eq 0 ] && grep -q "reusing issue board 7" "$TMPBASE/out"' "rc=$rc out=[$(cat "$TMPBASE/out")] err=[$(cat "$TMPBASE/err")]"
check "subgroup ensure-project: every glab api call encodes the path as $ENC" '[ -s "$GLAB_API_LOG" ] && ! grep -q "projects/grp/" "$GLAB_API_LOG" && grep -qF "projects/$ENC/boards/7/lists" "$GLAB_API_LOG"' "log=[$(cat "$GLAB_API_LOG" 2>/dev/null)]"
case_end

case_begin "RS-github-3seg-reject" "skills/migrate-tracker/scripts/run-issue-setup.sh"
for pair in "github|$R_GH" "unknown-host|$R_OTHER"; do
  IFS='|' read -r label root <<<"$pair"
  for step in labels check-project ensure-project record-done; do
    reset_logs
    ris "$NO_BIN" --step "$step" --repo grp/sub/proj --root "$root"; rc=$?
    check "$label --root, $step, 3 segments: exit 2 naming $SEG_MSG" '[ "$rc" -eq 2 ] && head -1 "$TMPBASE/err" | grep -q "^Error: invalid --repo value" && grep -qF -- "$SEG_MSG" "$TMPBASE/err"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
    check "$label --root, $step, 3 segments: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"
  done
done
case_end

case_begin "RS-no-root-3seg-reject" "skills/migrate-tracker/scripts/run-issue-setup.sh"
for step in labels check-project ensure-project; do
  for dry in "" --dry-run; do
    reset_logs
    # shellcheck disable=SC2086  # an empty $dry is no argument
    ris "$NO_BIN" --step "$step" --repo grp/sub/proj $dry; rc=$?
    check "no --root, $step ${dry:-(real)}, 3 segments: exit 2 naming $SEG_MSG" '[ "$rc" -eq 2 ] && grep -qF -- "$SEG_MSG" "$TMPBASE/err"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
    check "no --root, $step ${dry:-(real)}, 3 segments: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"
  done
done
case_end

case_begin "RS-format-reject" "skills/migrate-tracker/scripts/run-issue-setup.sh"
BAD=($'grp/sub\nproj' $'grp/sub/proj\n' "grp/../proj" "grp/./proj" "grp//proj" "../grp/proj" "grp/sub/.." "grp/sub/" "/grp/proj" "grp/sub proj" "grp/sub;x/proj")
for bad in "${BAD[@]}"; do
  shown="$(printf '%q' "$bad")"
  reset_logs
  ris "$GL_BIN" --step labels --repo "$bad" --root "$R_GL"; rc=$?
  check "gitlab --root, --repo $shown: exit 2 with the invalid --repo prefix" '[ "$rc" -eq 2 ] && head -1 "$TMPBASE/err" | grep -q "^Error: invalid --repo value"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
  check "gitlab --root, --repo $shown: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" "$TMPBASE/glab.log" 2>/dev/null)"
done
case_end

case_begin "RS-2seg-unchanged" "skills/migrate-tracker/scripts/run-issue-setup.sh"
reset_logs
ris "$NO_BIN" --step labels --repo o/r --root "$R_GH" --dry-run; rc=$?
check "github 2 segments --dry-run: exit 0 naming o/r on github" '[ "$rc" -eq 0 ] && grep -qF "o/r (github)" "$TMPBASE/out"' "rc=$rc err=[$(cat "$TMPBASE/err")]"
ris "$NO_BIN" --step labels --repo my-org.x/re_po.y --dry-run; rc=$?
check "no --root 2 segments --dry-run: exit 0" '[ "$rc" -eq 0 ]' "rc=$rc err=[$(cat "$TMPBASE/err")]"
ris "$NO_BIN" --step record-done --repo o/r --root "$R_GH" --dry-run; rc=$?
check "github 2 segments record-done --dry-run: origin matches (rc 0)" '[ "$rc" -eq 0 ]' "rc=$rc err=[$(cat "$TMPBASE/err")]"
check "2 segments --dry-run: no forge call" 'no_forge' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
