#!/usr/bin/env bash
# tests/bin/feature-2473-commit-path.sh
# Tests: bin/github-issues/migration/commit-migration-artifacts.sh, skills/migrate-tracker/scripts/run-issue-setup.sh, bin/repo-settings, bin/migrate-needs
# Tags: TL2, bin, migrate, repo-settings, github-issues, scope:issue-specific, test-lang-exception:e2e
# Issue #2473: each /migrate-* skill commits .agents.json via commit-migration-artifacts.sh --skill;
# record-done refusals write nothing; --skill migrate recovers a left-over .agents.json.
# Contract: the #2473 detail plan (commit path / record-done steps).
# TL3 gap: a real GitHub remote and Projects v2 board; here origin's pushurl is a local bare repo
# and the board check is a mock preflight.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE

CMA="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/commit-migration-artifacts.sh"
RS="$SCRIPT_CHECKOUT_ROOT/bin/repo-settings"
MN="$SCRIPT_CHECKOUT_ROOT/bin/migrate-needs"
RIS_REL="skills/migrate-tracker/scripts/run-issue-setup.sh"
TESTS_JSON='{"categorization":"flat","testHarness":"off","caseMarker":"off"}'
DONE_JSON='{"tests":{"dir":"tests","categorization":"flat","testHarness":"off","caseMarker":"off"},"migrate":{"tracker":"done","issues":"done"}}'

# gh / glab must never be reached: the board check below is a mock preflight.
MOCK_BIN="$TMPBASE/mock-bin"
mkdir -p "$MOCK_BIN"
for tool in gh glab; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>"%s/forge.log"\nexit 1\n' "$tool" "$TMPBASE" >"$MOCK_BIN/$tool"
  chmod +x "$MOCK_BIN/$tool"
done
export PATH="$MOCK_BIN:$PATH"

# fx <name> — repo on branch main, origin url github o/r, pushurl a bare repo; first commit pushed.
fx() {
  local d="$TMPBASE/$1"
  git init -q --bare "$d.git"
  harness_git_init "$d"
  git -C "$d" checkout -q -b main
  git -C "$d" remote add origin https://github.com/o/r.git
  git -C "$d" config remote.origin.pushurl "$d.git"
  git -C "$d" config user.name t
  git -C "$d" config user.email t@example.com
  git -C "$d" config core.autocrlf false
  mkdir -p "$d/.github"
  printf 'labels: []\n' >"$d/.github/labels.yml"
  printf 'fixture\n' >"$d/README"
  git -C "$d" add -A
  git -C "$d" commit -q --no-verify -m init
  git -C "$d" push -q origin main 2>/dev/null
  printf '%s' "$d"
}
count() { git -C "$1" rev-list --count HEAD; }
head_files() { git -C "$1" show --name-only --format= HEAD | tr -d '\r' | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//'; }
subject() { git -C "$1" log -1 --format=%s; }
pushed() { [ "$(git -C "$1.git" rev-parse main 2>/dev/null)" = "$(git -C "$1" rev-parse HEAD)" ]; }
# head_json <repo> <js-expression over j> — exit 0 when HEAD's .agents.json satisfies it.
head_json() {
  git -C "$1" show HEAD:.agents.json 2>/dev/null |
    node -e 'let s="";process.stdin.on("data",(c)=>s+=c).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){process.exit(1)}process.exit((new Function("j","return "+process.argv[1]))(j)?0:1)})' "$2"
}
dirty() { git -C "$1" status --porcelain -- "$2" | tr -d '\r'; }
# committed_clean <repo> — .agents.json is tracked at HEAD and has no pending change.
committed_clean() { git -C "$1" cat-file -e HEAD:.agents.json 2>/dev/null && [ -z "$(dirty "$1" .agents.json)" ]; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

# A fake checkout holding the real bin/ and hooks/ and the migrate-tracker skill, with a mock board
# check (preflight --check-project answers GH_MOCK_PROJECT_RC).
FAKE="$TMPBASE/fake-checkout"
ris_ready() {
  [ -f "$SCRIPT_CHECKOUT_ROOT/$RIS_REL" ] || return 1
  [ -d "$FAKE" ] && return 0
  mkdir -p "$FAKE/skills" "$FAKE/.github"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin" "$SCRIPT_CHECKOUT_ROOT/hooks" "$FAKE/"
  cp -R "$SCRIPT_CHECKOUT_ROOT/skills/migrate-tracker" "$FAKE/skills/"
  : >"$FAKE/.github/labels.yml"
  printf '#!/usr/bin/env bash\ncase "$*" in *--check-project*) exit "${GH_MOCK_PROJECT_RC:-0}" ;; *) exit 0 ;; esac\n' >"$FAKE/bin/github-issues/issue-create-preflight.sh"
  chmod +x "$FAKE/bin/github-issues/issue-create-preflight.sh"
}
NO_RIS="$RIS_REL does not exist yet"

case_begin "CP-tests-route" "bin/github-issues/migration/commit-migration-artifacts.sh"
R="$(fx tests-route)"
printf 'labels: [changed]\n' >"$R/.github/labels.yml"
node "$RS" --root "$(np "$R")" --write-tests "$TESTS_JSON" >/dev/null 2>&1
rc_w=$?
bash "$CMA" "$R" --skill migrate-tests >"$TMPBASE/out" 2>&1; rc=$?
check "tests route: --write-tests and the commit succeed" '[ "$rc_w" -eq 0 ] && [ "$rc" -eq 0 ]' "write=$rc_w commit=$rc $(tail -3 "$TMPBASE/out")"
check "tests route: HEAD holds .agents.json with the tests section" 'head_json "$R" "j.tests && j.tests.categorization===\"flat\""'
check "tests route: the commit holds .agents.json only (labels.yml not staged)" '[ "$(head_files "$R")" = ".agents.json" ] && [ -n "$(dirty "$R" .github/labels.yml)" ]' "files=[$(head_files "$R")]"
check "tests route: subject names /migrate-tests" 'subject "$R" | grep -q "/migrate-tests"' "subject=$(subject "$R")"
check "tests route: .agents.json is clean and the commit is pushed" 'committed_clean "$R" && pushed "$R"'
case_end

case_begin "CP-issues-route-no-push" "bin/github-issues/migration/commit-migration-artifacts.sh"
R="$(fx issues-route)"
before_bare="$(git -C "$R.git" rev-parse main)"
node "$RS" --root "$(np "$R")" --set-migrate issues >/dev/null 2>&1
rc_s=$?
bash "$CMA" "$R" --skill migrate-issues --no-push >"$TMPBASE/out" 2>&1; rc=$?
check "issues route: --set-migrate and the commit succeed" '[ "$rc_s" -eq 0 ] && [ "$rc" -eq 0 ]' "set=$rc_s commit=$rc $(tail -3 "$TMPBASE/out")"
check "issues route: HEAD holds migrate.issues done" 'head_json "$R" "j.migrate && j.migrate.issues===\"done\""'
check "issues route: subject names /migrate-issues" 'subject "$R" | grep -q "/migrate-issues"' "subject=$(subject "$R")"
check "issues route: .agents.json is clean" 'committed_clean "$R"'
check "issues route: --no-push leaves the bare repo where it was" '[ "$(git -C "$R.git" rev-parse main)" = "$before_bare" ] && [ "$(count "$R")" -eq 2 ]'
case_end

case_begin "CP-rerun-idempotent" "bin/github-issues/migration/commit-migration-artifacts.sh"
for skill in migrate-tests migrate-issues migrate-tracker migrate; do
  R="$(fx "rerun-$skill")"
  case "$skill" in
    migrate-tests) node "$RS" --root "$(np "$R")" --write-tests "$TESTS_JSON" >/dev/null 2>&1 ;;
    migrate-issues) node "$RS" --root "$(np "$R")" --set-migrate issues >/dev/null 2>&1 ;;
    migrate-tracker) node "$RS" --root "$(np "$R")" --set-migrate tracker >/dev/null 2>&1 ;;
    migrate) printf '%s\n' "$DONE_JSON" >"$R/.agents.json" ;;
  esac
  bash "$CMA" "$R" --skill "$skill" >"$TMPBASE/out" 2>&1
  rc1=$?
  head1="$(git -C "$R" rev-parse HEAD)"
  bare1="$(git -C "$R.git" rev-parse main 2>/dev/null)"
  bash "$CMA" "$R" --skill "$skill" >"$TMPBASE/out2" 2>&1
  rc2=$?
  check "rerun $skill: the first run commits and pushes .agents.json" '[ "$rc1" -eq 0 ] && [ "$(count "$R")" -eq 2 ] && [ "$bare1" = "$head1" ]' "rc=$rc1 commits=$(count "$R") $(tail -3 "$TMPBASE/out")"
  check "rerun $skill: the second run succeeds and moves neither HEAD nor the bare repo" '[ "$rc2" -eq 0 ] && [ "$(git -C "$R" rev-parse HEAD)" = "$head1" ] && [ "$(git -C "$R.git" rev-parse main 2>/dev/null)" = "$bare1" ] && committed_clean "$R"' "rc=$rc2 $(tail -3 "$TMPBASE/out2")"
done
case_end

case_begin "CP-tracker-route" "skills/migrate-tracker/scripts/run-issue-setup.sh"
if ! ris_ready; then
  fail "CP-tracker-route" "$NO_RIS"
else
  R="$(fx tracker-route)"
  printf 'labels: [changed]\n' >"$R/.github/labels.yml"
  bash "$FAKE/$RIS_REL" --step record-done --repo o/r --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
  check "tracker route: record-done succeeds" '[ "$rc" -eq 0 ]' "rc=$rc $(tail -3 "$TMPBASE/out")"
  check "tracker route: HEAD holds migrate.tracker done" 'head_json "$R" "j.migrate && j.migrate.tracker===\"done\""'
  check "tracker route: the commit holds .agents.json only (labels.yml not staged)" '[ "$(head_files "$R")" = ".agents.json" ] && [ -n "$(dirty "$R" .github/labels.yml)" ]' "files=[$(head_files "$R")]"
  check "tracker route: subject names /migrate-tracker" 'subject "$R" | grep -q "/migrate-tracker"' "subject=$(subject "$R")"
  check "tracker route: .agents.json is clean and the commit is pushed" 'committed_clean "$R" && pushed "$R"'
fi
case_end

case_begin "CP-record-done-refusals" "skills/migrate-tracker/scripts/run-issue-setup.sh"
if ! ris_ready; then
  fail "CP-record-done-refusals" "$NO_RIS"
else
  for spec in "no-root:x:o/r:0" "origin-mismatch:2:other/x:0" "no-board:1:o/r:1"; do
    IFS=: read -r label want repo board <<<"$spec"
    R="$(fx "rd-$label")"
    n0="$(count "$R")"
    if [ "$label" = "no-root" ]; then
      (cd "$R" && GH_MOCK_PROJECT_RC="$board" bash "$FAKE/$RIS_REL" --step record-done --repo "$repo") >"$TMPBASE/out" 2>&1
    else
      GH_MOCK_PROJECT_RC="$board" bash "$FAKE/$RIS_REL" --step record-done --repo "$repo" --root "$R" >"$TMPBASE/out" 2>&1
    fi
    rc=$?
    if [ "$want" = "x" ]; then ok_rc='[ "$rc" -ne 0 ]'; else ok_rc='[ "$rc" -eq "$want" ]'; fi
    check "record-done $label: refused (rc=$rc)" "$ok_rc" "$(tail -3 "$TMPBASE/out")"
    check "record-done $label: no .agents.json written, no commit added" '[ ! -e "$R/.agents.json" ] && [ "$(count "$R")" -eq "$n0" ]'
  done
fi
case_end

# A --repo that is not whole-string OWNER/REPO is refused before any dispatch on every step. The mock
# preflight logs nothing, so check-project's rc=2 is the proof it was not reached: a run reaching it
# answers the mock rc 0, as the sanctioned counterpart below shows.
case_begin "CP-repo-format-refusals" "skills/migrate-tracker/scripts/run-issue-setup.sh"
if ! ris_ready; then
  fail "CP-repo-format-refusals" "$NO_RIS"
else
  R="$(fx repo-format)"
  n0="$(count "$R")"
  CANARY="$TMPBASE/repo-canary"
  for bad in $'o/r\nx' $'o/r\n' "o/r;touch $CANARY" 'o/r$(touch '"$CANARY"')' 'o/r`touch '"$CANARY"'`' 'o/r|x' 'o/r x' 'o/r&x' 'noslash' 'o/r/x' '/r' 'o/'; do
    printf -v shown '%q' "$bad"
    for step in labels check-project ensure-project record-done; do
      GH_MOCK_PROJECT_RC=0 bash "$FAKE/$RIS_REL" --step "$step" --repo "$bad" --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
      check "bad --repo $shown $step: exit 2 with the invalid --repo line, no canary, no .agents.json, no commit" '[ "$rc" -eq 2 ] && grep -q "^Error: invalid --repo value" "$TMPBASE/out" && [ ! -e "$CANARY" ] && [ ! -e "$R/.agents.json" ] && [ "$(count "$R")" -eq "$n0" ]' "rc=$rc $(tail -3 "$TMPBASE/out")"
    done
  done
  GH_MOCK_PROJECT_RC=0 bash "$FAKE/$RIS_REL" --step check-project "--repo=o/r;x" --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
  check "bad --repo=VALUE form: exit 2 with the invalid --repo line" '[ "$rc" -eq 2 ] && grep -q "^Error: invalid --repo value" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
  check "bad --repo: gh and glab were not started (forge.log empty)" '[ ! -s "$TMPBASE/forge.log" ]' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"
  GH_MOCK_PROJECT_RC=0 bash "$FAKE/$RIS_REL" --step check-project --repo o/r --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
  check "sanctioned --repo o/r check-project: reaches the mock preflight, exit 0" '[ "$rc" -eq 0 ] && ! grep -q "invalid --repo" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
  bash "$FAKE/$RIS_REL" --step labels --repo my-org.x/re_po.y --root "$R" --dry-run >"$TMPBASE/out" 2>&1; rc=$?
  check "sanctioned dotted/hyphenated --repo: exit 0, planned, no invalid --repo" '[ "$rc" -eq 0 ] && ! grep -q "invalid --repo" "$TMPBASE/out" && grep -q "would sync the labels of my-org.x/re_po.y" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
fi
case_end

case_begin "CP-skill-required" "bin/github-issues/migration/commit-migration-artifacts.sh"
for args in "" "--skill nonsense"; do
  name="skill-${args:-none}"
  R="$(fx "${name// /-}")"
  printf '%s\n' "$DONE_JSON" >"$R/.agents.json"
  n0="$(count "$R")"
  # shellcheck disable=SC2086
  bash "$CMA" "$R" $args --no-push >"$TMPBASE/out" 2>&1; rc=$?
  check "--skill '${args:-<absent>}': exit 1" '[ "$rc" -eq 1 ]' "rc=$rc $(tail -2 "$TMPBASE/out")"
  check "--skill '${args:-<absent>}': nothing committed" '[ "$(count "$R")" -eq "$n0" ]'
done
case_end

case_begin "CP-recovery-skill-migrate" "bin/github-issues/migration/commit-migration-artifacts.sh"
R="$(fx recovery)"
printf '%s\n' "$DONE_JSON" >"$R/.agents.json"
bash "$CMA" "$R" --skill migrate --no-push >"$TMPBASE/out" 2>&1; rc=$?
check "recovery: --skill migrate commits the left-over .agents.json" '[ "$rc" -eq 0 ] && [ "$(head_files "$R")" = ".agents.json" ]' "rc=$rc $(tail -2 "$TMPBASE/out")"
mn="$(cd "$R" && node "$MN" --root "$(np "$R")" 2>&1)"
check "recovery: bin/migrate-needs then reports NEEDED empty and UNCOMMITTED=0" 'printf "%s\n" "$mn" | grep -qx "NEEDED=" && printf "%s\n" "$mn" | grep -qx "UNCOMMITTED=0"' "$mn"
case_end

# /migrate-tracker on a gitlab origin: labels go through glab label create, the board step says
# that Content Date has no GitLab counterpart and skips it, and gh is never started. The case has
# its own PATH dir (a glab mock first, gh as a stub that exits 97), so forge.log stays the record
# of the cases above. Assumed surface (the plan names none): the host comes from --root's origin,
# and the labels come from the script checkout's .github/labels.yml as on GitHub.
GL_BIN="$TMPBASE/gitlab-bin"
mkdir -p "$GL_BIN"
export CP_GL_DIR="$TMPBASE"
# glab api answers a write to .../boards with board 5, a write to .../lists with list 3, a read of
# labels with the two fixture labels, a read of a board's lists with one list for status:migrated
# (id 12, so the post-create check finds every status:* label listed), any other read with [].
cat >"$GL_BIN/glab" <<'GLAB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CP_GL_DIR/glab.log"
[ "$1" = api ] || exit 0
w=0
case " $* " in *" -X POST "*|*" -XPOST "*|*" --method POST "*|*" --method=POST "*|*" -f "*|*" -F "*|*" --field "*|*" --raw-field "*|*" --field="*|*" --raw-field="*) w=1 ;; esac
case "$w:$*" in
  1:*lists*) echo '{"id":3}' ;;
  1:*boards*) echo '{"id":5,"name":"board"}' ;;
  0:*boards/*/lists*) echo '[{"id":3,"label":{"id":12,"name":"status:migrated"}}]' ;;
  0:*labels*) echo '[{"id":11,"name":"type:task"},{"id":12,"name":"status:migrated"}]' ;;
  *) echo '[]' ;;
esac
exit 0
GLAB
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >>"%s/forbidden.log"\necho "gh must not be started for a gitlab origin" >&2\nexit 97\n' "$TMPBASE" >"$GL_BIN/gh"
chmod +x "$GL_BIN/glab" "$GL_BIN/gh"
FAKE_GL="$TMPBASE/fake-checkout-gitlab"
GL_LABELS='- name: "type:task"\n  color: "0e8a16"\n  description: "task"\n- name: "status:migrated"\n  color: "cccccc"\n  description: "migrated"\n'
GL_WRITE_RE='(^| )(-X ?POST|--method[ =]POST|-[fF]|--(raw-)?field)( |=|$)'
# gl_board_made <glab log> — the log holds a glab api write to a project's boards and one to a
# board's lists (the GitLab counterpart of the board and its label lists).
gl_board_made() {
  grep -E '^api ' "$1" 2>/dev/null | grep -E "$GL_WRITE_RE" | grep -qE 'boards( |$)' &&
    grep -E '^api ' "$1" 2>/dev/null | grep -E "$GL_WRITE_RE" | grep -qE 'boards/[^ ]+/lists( |$)'
}

case_begin "CP-gitlab-board-check-rejects" "skills/migrate-tracker/scripts/run-issue-setup.sh"
GLN="$TMPBASE/glab-negative"
mkdir -p "$GLN"
printf 'label create type:task\napi projects/o%%2Fr/boards\napi projects/o%%2Fr/labels\n' >"$GLN/labels-only.log"
printf 'api projects/o%%2Fr/boards -X POST -f name=board\n' >"$GLN/board-no-list.log"
printf 'api projects/o%%2Fr/boards/5/lists -X POST -f label_id=11\n' >"$GLN/list-no-board.log"
printf 'api projects/o%%2Fr/boards -X POST -f name=board\napi projects/o%%2Fr/boards/5/lists -f label_id=11\n' >"$GLN/both.log"
for neg in labels-only board-no-list list-no-board; do
  check "board check: a glab log with $neg is not a made board" '! gl_board_made "$GLN/$neg.log"' "$(cat "$GLN/$neg.log")"
done
check "board check: a glab log with both writes is a made board" 'gl_board_made "$GLN/both.log"'
case_end

case_begin "CP-tracker-gitlab" "skills/migrate-tracker/scripts/run-issue-setup.sh"
if ! ris_ready; then
  fail "CP-tracker-gitlab" "$NO_RIS"
else
  cp -R "$FAKE" "$FAKE_GL"
  # shellcheck disable=SC2059  # the format is the fixture text itself
  printf -- "$GL_LABELS" >"$FAKE_GL/.github/labels.yml"
  R="$(fx tracker-gitlab)"
  git -C "$R" remote set-url origin git@gitlab.com:o/r.git
  rm -f "$TMPBASE/glab.log" "$TMPBASE/forbidden.log"
  PATH="$GL_BIN:$PATH" bash "$FAKE_GL/$RIS_REL" --step labels --repo o/r --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
  n_label="$(grep -c 'label create' "$TMPBASE/glab.log" 2>/dev/null)"
  check "tracker gitlab labels: succeeds with one glab label create per labels.yml entry" '[ "$rc" -eq 0 ] && [ "${n_label:-0}" -eq 2 ]' "rc=$rc glab=[$(cat "$TMPBASE/glab.log" 2>/dev/null)] $(tail -3 "$TMPBASE/out")"
  check "tracker gitlab labels: gh is never started" '[ ! -s "$TMPBASE/forbidden.log" ]' "$(cat "$TMPBASE/forbidden.log" 2>/dev/null)"
  rm -f "$TMPBASE/forbidden.log" "$TMPBASE/glab.log"
  PATH="$GL_BIN:$PATH" bash "$FAKE_GL/$RIS_REL" --step ensure-project --repo o/r --root "$R" >"$TMPBASE/out" 2>&1; rc=$?
  check "tracker gitlab board: succeeds and says the Content Date step is skipped" '[ "$rc" -eq 0 ] && grep -i "content date" "$TMPBASE/out" | grep -qi "skip"' "rc=$rc $(tail -5 "$TMPBASE/out")"
  check "tracker gitlab board: glab api creates a board and a label list on it" 'gl_board_made "$TMPBASE/glab.log"' "glab=[$(cat "$TMPBASE/glab.log" 2>/dev/null)]"
  check "tracker gitlab board: gh is never started" '[ ! -s "$TMPBASE/forbidden.log" ]' "$(cat "$TMPBASE/forbidden.log" 2>/dev/null)"
fi
case_end

# --dry-run: labels / ensure-project / record-done print "[dry-run] would ..." and exit 0 with no
# gh / glab start (MOCK_BIN logs any to forge.log), no .agents.json, no commit and no push.
case_begin "CP-tracker-dry-run" "skills/migrate-tracker/scripts/run-issue-setup.sh"
if ! ris_ready; then
  fail "CP-tracker-dry-run" "$NO_RIS"
else
  for spec in "github|https://github.com/o/r.git" "gitlab|git@gitlab.com:o/r.git"; do
    host="${spec%%|*}"
    R="$(fx "dry-$host")"
    git -C "$R" remote set-url origin "${spec#*|}"
    n0="$(count "$R")"
    bare0="$(git -C "$R.git" rev-parse main)"
    for step in labels ensure-project record-done; do
      bash "$FAKE/$RIS_REL" --step "$step" --repo o/r --root "$R" --dry-run >"$TMPBASE/out" 2>&1; rc=$?
      check "dry-run $host $step: exit 0 with a [dry-run] would line" '[ "$rc" -eq 0 ] && grep -q "^\[dry-run\] would" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
      check "dry-run $host $step: no .agents.json, no commit, no push, no gh / glab" '[ ! -e "$R/.agents.json" ] && [ "$(count "$R")" -eq "$n0" ] && [ "$(git -C "$R.git" rev-parse main)" = "$bare0" ] && [ ! -s "$TMPBASE/forge.log" ]' "forge=[$(cat "$TMPBASE/forge.log" 2>/dev/null)]"
    done
  done
  R="$(fx dry-plan)"
  bash "$FAKE/$RIS_REL" --step record-done --repo o/r --root "$R" --dry-run >"$TMPBASE/out" 2>&1
  check "dry-run record-done: the plan says commit and push" 'grep -q "commit and push" "$TMPBASE/out"' "$(cat "$TMPBASE/out")"
  bash "$FAKE/$RIS_REL" --step record-done --repo o/r --root "$R" --dry-run --no-push >"$TMPBASE/out" 2>&1
  check "dry-run record-done --no-push: the plan commits without a push" 'grep -q "would set migrate.tracker done" "$TMPBASE/out" && ! grep -q push "$TMPBASE/out"' "$(cat "$TMPBASE/out")"
  (cd "$R" && bash "$FAKE/$RIS_REL" --step labels --repo o/r --dry-run) >"$TMPBASE/out" 2>&1; rc=$?
  check "dry-run labels without --root: exit 0, github plan" '[ "$rc" -eq 0 ] && grep -q "^\[dry-run\] would sync the labels of o/r (github)" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
  bash "$FAKE/$RIS_REL" --step record-done --repo other/x --root "$R" --dry-run >"$TMPBASE/out" 2>&1; rc=$?
  check "dry-run record-done with an origin mismatch: exit 2, no plan line" '[ "$rc" -eq 2 ] && ! grep -q "dry-run" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
  (cd "$R" && bash "$FAKE/$RIS_REL" --step record-done --repo o/r --dry-run) >"$TMPBASE/out" 2>&1; rc=$?
  check "dry-run record-done without --root: exit 2" '[ "$rc" -eq 2 ]' "rc=$rc $(cat "$TMPBASE/out")"
  for board in 0 1; do
    GH_MOCK_PROJECT_RC="$board" bash "$FAKE/$RIS_REL" --step check-project --repo o/r --root "$R" --dry-run >"$TMPBASE/out" 2>&1; rc=$?
    check "dry-run check-project still reads the board (mock rc=$board)" '[ "$rc" -eq "$board" ]' "rc=$rc $(cat "$TMPBASE/out")"
  done
  check "dry-run refusals and plans wrote nothing" '[ ! -e "$R/.agents.json" ] && [ "$(count "$R")" -eq 1 ]'
fi
case_end

# Push retry: a commit whose push failed is pushed by the next run (not with --no-push).
mn_of() { (cd "$1" && node "$MN" --root "$(np "$1")" 2>&1) | tr -d '\r'; }
case_begin "CP-push-retry" "bin/github-issues/migration/commit-migration-artifacts.sh"
R="$(fx push-retry)"
git -C "$R" branch --set-upstream-to=origin/main >/dev/null 2>&1
bare0="$(git -C "$R.git" rev-parse main)"
printf '%s\n' "$DONE_JSON" >"$R/.agents.json"
git -C "$R" config remote.origin.pushurl "$TMPBASE/no-such-remote.git"
bash "$CMA" "$R" --skill migrate >"$TMPBASE/out" 2>&1; rc=$?
check "push retry: the push fails after the commit (exit non-zero, bare repo unchanged)" '[ "$rc" -ne 0 ] && [ "$(count "$R")" -eq 2 ] && committed_clean "$R" && [ "$(git -C "$R.git" rev-parse main)" = "$bare0" ]' "rc=$rc $(tail -3 "$TMPBASE/out")"
mn="$(mn_of "$R")"
check "push retry: bin/migrate-needs reports UNCOMMITTED=0 and UNPUSHED=1" 'grep -qx UNCOMMITTED=0 <<<"$mn" && grep -qx UNPUSHED=1 <<<"$mn"' "$mn"
git -C "$R" config remote.origin.pushurl "$R.git"
bash "$CMA" "$R" --skill migrate --no-push >"$TMPBASE/out" 2>&1; rc=$?
mn="$(mn_of "$R")"
check "push retry --no-push: exit 0, nothing pushed, UNPUSHED stays 1" '[ "$rc" -eq 0 ] && [ "$(git -C "$R.git" rev-parse main)" = "$bare0" ] && grep -qx UNPUSHED=1 <<<"$mn"' "rc=$rc $mn"
bash "$CMA" "$R" --skill migrate >"$TMPBASE/out" 2>&1; rc=$?
mn="$(mn_of "$R")"
check "push retry: the re-run pushes the earlier commit without a new one" '[ "$rc" -eq 0 ] && [ "$(count "$R")" -eq 2 ] && pushed "$R" && grep -q "not on origin yet" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
check "push retry: bin/migrate-needs then reports UNPUSHED=0" 'grep -qx UNPUSHED=0 <<<"$mn" && grep -qx UNCOMMITTED=0 <<<"$mn"' "$mn"
case_end

case_begin "CP-push-retry-boundaries" "bin/github-issues/migration/commit-migration-artifacts.sh"
R="$(fx push-retry-no-upstream)"
printf '%s\n' "$DONE_JSON" >"$R/.agents.json"
git -C "$R" config remote.origin.pushurl "$TMPBASE/no-such-remote.git"
bash "$CMA" "$R" --skill migrate >/dev/null 2>&1
git -C "$R" config remote.origin.pushurl "$R.git"
bash "$CMA" "$R" --skill migrate >"$TMPBASE/out" 2>&1; rc=$?
check "push retry without upstream: the re-run still pushes (origin refs as the base)" '[ "$rc" -eq 0 ] && [ "$(count "$R")" -eq 2 ] && pushed "$R"' "rc=$rc $(tail -3 "$TMPBASE/out")"
R="$(fx push-retry-other)"
git -C "$R" branch --set-upstream-to=origin/main >/dev/null 2>&1
bare0="$(git -C "$R.git" rev-parse main)"
printf 'changed\n' >"$R/README"
git -C "$R" commit -qam other --no-verify
bash "$CMA" "$R" --skill migrate >"$TMPBASE/out" 2>&1; rc=$?
check "push retry: an unpushed commit outside the allowlist is not pushed" '[ "$rc" -eq 0 ] && [ "$(git -C "$R.git" rev-parse main)" = "$bare0" ] && ! grep -q "not on origin yet" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
case_end

cma() { bash "$CMA" "$@" >"$TMPBASE/out" 2>&1; rc=$?; }
# ps_fx <name> [json] — sets R: fx with README part-staged and a new text and binary file staged; saves the staged diff and the tree.
ps_fx() {
  R="$(fx "$1")"
  printf 'staged\n' >>"$R/README"; printf 'new\n' >"$R/unrelated.txt"; printf '\000\001\377\n' >"$R/unrelated.bin"
  git -C "$R" add -- README unrelated.txt unrelated.bin; printf 'unstaged\n' >>"$R/README"
  git -C "$R" diff --cached --binary >"$R.staged"; mkdir -p "$R.tree"; cp "$R/README" "$R/unrelated.txt" "$R/unrelated.bin" "$R.tree/"
  [ -z "${2:-}" ] || printf '%s\n' "$DONE_JSON" >"$R/.agents.json"
}
ps_check() {
  git -C "$R" diff --cached --binary -- README unrelated.txt unrelated.bin >"$R.after"
  check "$1: the unrelated staging is byte-identical, README stays part-staged" '[ -s "$R.staged" ] && cmp -s "$R.staged" "$R.after" && [ "$(dirty "$R" README)" = "MM README" ]' "$(git -C "$R" status --porcelain)"
  check "$1: the working tree copies are unchanged" 'cmp -s "$R/README" "$R.tree/README" && cmp -s "$R/unrelated.txt" "$R.tree/unrelated.txt" && cmp -s "$R/unrelated.bin" "$R.tree/unrelated.bin"'
}

case_begin "CP-prestaged-preserved" "bin/github-issues/migration/commit-migration-artifacts.sh"
ps_fx prestaged json
cma "$R" --skill migrate-tests --no-push
check "prestaged: exit 0, the commit holds .agents.json only" '[ "$rc" -eq 0 ] && [ "$(count "$R")" -eq 2 ] && [ "$(head_files "$R")" = ".agents.json" ] && committed_clean "$R"' "rc=$rc files=[$(head_files "$R")] $(tail -3 "$TMPBASE/out")"
ps_check prestaged
case_end

case_begin "CP-prestaged-commit-failure" "bin/github-issues/migration/commit-migration-artifacts.sh"
ps_fx prestaged-fail json
# fx pins core.hooksPath to /dev/null; a path relative to the worktree top makes this hook fire.
git -C "$R" config core.hooksPath .git/hooks; mkdir -p "$R/.git/hooks"
printf '#!/bin/sh\n: >.git/hook-fired\nexit 1\n' >"$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
cma "$R" --skill migrate-tests --no-push
check "prestaged commit failure: the hook fired, exit non-zero, no new commit" '[ "$rc" -ne 0 ] && [ -e "$R/.git/hook-fired" ] && [ "$(count "$R")" -eq 1 ]' "rc=$rc $(tail -3 "$TMPBASE/out")"
ps_check "prestaged commit failure"
case_end

case_begin "CP-prestaged-nothing-to-commit" "bin/github-issues/migration/commit-migration-artifacts.sh"
ps_fx prestaged-only
bare0="$(git -C "$R.git" rev-parse main)"
cma "$R" --skill migrate-tests
check "prestaged only: exit 0, nothing to commit, no commit, no push" '[ "$rc" -eq 0 ] && grep -q "nothing to commit" "$TMPBASE/out" && [ "$(count "$R")" -eq 1 ] && [ "$(git -C "$R.git" rev-parse main)" = "$bare0" ]' "rc=$rc $(tail -3 "$TMPBASE/out")"
ps_check "prestaged only"
case_end

case_begin "CP-dry-run-push-line" "bin/github-issues/migration/commit-migration-artifacts.sh"
E="$TMPBASE/dry-push-no-commit"; harness_git_init "$E"; R="$(fx dry-push)"
for d in "$E" "$R"; do
  cma "$d" --skill migrate-tests --dry-run --no-push
  check "dry-run --no-push ${d##*/}: exit 0, no would push line" '[ "$rc" -eq 0 ] && [ "$(grep -c "would push" "$TMPBASE/out")" -eq 0 ]' "rc=$rc $(cat "$TMPBASE/out")"
  cma "$d" --skill migrate-tests --dry-run
  check "dry-run ${d##*/}: exit 0, one would push line, every line a plan line" '[ "$rc" -eq 0 ] && [ "$(grep -c "would push" "$TMPBASE/out")" -eq 1 ] && ! grep -qvE "^(\[dry-run\] |  - )" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
done
check "dry-run: the would push line of R (run last) names origin and the branch" 'grep -Fxq "[dry-run] would push: origin main" "$TMPBASE/out"' "$(cat "$TMPBASE/out")"
case_end

# pt_fx <name> <0|1> — sets R: on branch feature (1: pushed at the base), with an allowlist commit on origin/main, the upstream.
pt_fx() {
  R="$(fx "$1")"; git -C "$R" checkout -q -b feature
  [ "$2" = 0 ] || git -C "$R" push -q origin feature 2>/dev/null
  printf '%s\n' "$DONE_JSON" >"$R/.agents.json"; git -C "$R" add .agents.json; git -C "$R" commit -q --no-verify -m settings
  git -C "$R" push -q origin HEAD:main 2>/dev/null; git -C "$R" branch --set-upstream-to=origin/main >/dev/null 2>&1
}
case_begin "CP-push-target" "bin/github-issues/migration/commit-migration-artifacts.sh"
for up in main none; do
  pt_fx "pt-$up" 1
  [ "$up" = none ] && git -C "$R" branch --unset-upstream
  cma "$R" --skill migrate
  check "push target (upstream $up): origin/feature behind, the commit on origin/main: the re-run pushes feature" '[ "$rc" -eq 0 ] && [ "$(count "$R")" -eq 2 ] && [ "$(git -C "$R.git" rev-parse feature)" = "$(git -C "$R" rev-parse HEAD)" ] && grep -q "not on origin yet" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
done
pt_fx pt-synced 1
git -C "$R" push -q origin feature HEAD~1:refs/heads/base 2>/dev/null; git -C "$R" branch --set-upstream-to=origin/base >/dev/null 2>&1
cma "$R" --skill migrate
check "push target: origin/feature in sync, the upstream origin/base behind: no push" '[ "$rc" -eq 0 ] && ! grep -q "not on origin yet" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
pt_fx pt-fresh 0
cma "$R" --skill migrate
check "push target: no origin/feature, the commit on origin/main: a freshly cut branch is not pushed" '[ "$rc" -eq 0 ] && ! git -C "$R.git" rev-parse -q --verify refs/heads/feature >/dev/null && ! grep -q "not on origin yet" "$TMPBASE/out"' "rc=$rc $(tail -3 "$TMPBASE/out")"
case_end

# label-setup.sh (orchestrate.sh Step 1) from a fixture checkout whose sync-labels.sh and
# bootstrap-labels.sh are stubs logging "<name> <cwd> <args>" (sync exits LS_SYNC_RC).
LS_REL="bin/github-issues/migration/orchestrate/label-setup.sh"
LSF="$TMPBASE/label-setup-checkout"
mkdir -p "$LSF/${LS_REL%/*}" "$LSF/.github/ISSUE_TEMPLATE"
cp "$SCRIPT_CHECKOUT_ROOT/$LS_REL" "$LSF/$LS_REL"
printf 'labels: []\n' >"$LSF/.github/labels.yml"
printf 'name: task\n' >"$LSF/.github/ISSUE_TEMPLATE/task.yml"
for s in sync-labels bootstrap-labels; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s %%s\\n" "$PWD" "$*" >>"%s/ls.log"\n[ %s = sync-labels ] && exit "${LS_SYNC_RC:-0}"\nexit 0\n' "$s" "$TMPBASE" "$s" >"$LSF/bin/github-issues/$s.sh"
done
# ls_run <name> <host> [--dry-run] — label-setup.sh on an empty target T; sets rc, output in out.
ls_run() {
  T="$TMPBASE/ls-$1"
  rm -rf "$T" "$TMPBASE/ls.log"
  mkdir -p "$T"
  bash "$LSF/$LS_REL" "$T" "$2" ${3:+"$3"} >"$TMPBASE/out" 2>&1; rc=$?
}
lslog() { cat "$TMPBASE/ls.log" 2>/dev/null; }

case_begin "CP-label-setup-hosts" "bin/github-issues/migration/orchestrate/label-setup.sh"
ls_run gitlab gitlab
check "label-setup gitlab: syncs the checkout's labels.yml in the target, no bootstrap" '[ "$rc" -eq 0 ] && [ "$(lslog)" = "sync-labels $T $LSF/.github/labels.yml" ]' "rc=$rc log=[$(lslog)] $(tail -2 "$TMPBASE/out")"
check "label-setup gitlab: no .github/ in the target" '[ ! -e "$T/.github" ]' "$(ls -A "$T")"
ls_run github github
check "label-setup github: bootstrap --no-sync, then sync of .github/labels.yml in the target" '[ "$rc" -eq 0 ] && lslog | head -1 | grep -q "^bootstrap-labels .* $T --no-sync$" && [ "$(lslog | sed -n 2p)" = "sync-labels $T .github/labels.yml" ]' "rc=$rc log=[$(lslog)]"
check "label-setup github: the issue templates are copied" '[ -f "$T/.github/ISSUE_TEMPLATE/task.yml" ]'
case_end

case_begin "CP-label-setup-sync-failure" "bin/github-issues/migration/orchestrate/label-setup.sh"
for host in gitlab github; do
  LS_SYNC_RC=1 ls_run "fail-$host" "$host"
  check "label-setup $host: a failed sync exits 1 with the ERROR line" '[ "$rc" -eq 1 ] && grep -q "^ERROR: label sync failed ($host)" "$TMPBASE/out"' "rc=$rc $(cat "$TMPBASE/out")"
  check "label-setup $host: no issue template after a failed sync" '[ ! -e "$T/.github/ISSUE_TEMPLATE" ]'
done
case_end

case_begin "CP-label-setup-unknown-host" "bin/github-issues/migration/orchestrate/label-setup.sh"
for mode in "" --dry-run; do
  ls_run "unknown$mode" unknown "$mode"
  check "label-setup unknown ${mode:-live}: notice and exit 0, nothing run or written" '[ "$rc" -eq 0 ] && grep -q "unknown" "$TMPBASE/out" && grep -q "skipped" "$TMPBASE/out" && [ -z "$(lslog)" ] && [ -z "$(ls -A "$T")" ]' "rc=$rc $(cat "$TMPBASE/out") log=[$(lslog)]"
done
case_end

case_begin "CP-label-setup-dry-run" "bin/github-issues/migration/orchestrate/label-setup.sh"
for spec in github:3 gitlab:1; do
  ls_run "dry-${spec%%:*}" "${spec%%:*}" --dry-run
  n="$(grep -c '^\[dry-run\] would' "$TMPBASE/out")"
  check "label-setup ${spec%%:*} --dry-run: ${spec#*:} planned line(s), nothing run or written" '[ "$rc" -eq 0 ] && [ "$n" -eq "${spec#*:}" ] && [ -z "$(lslog)" ] && [ -z "$(ls -A "$T")" ]' "rc=$rc n=$n $(cat "$TMPBASE/out")"
done
check "label-setup gitlab --dry-run: the one line is the sync" 'grep -q "^\[dry-run\] would run in .*sync-labels\.sh" "$TMPBASE/out"' "$(cat "$TMPBASE/out")"
case_end

check "gh and glab were never started" '[ ! -s "$TMPBASE/forge.log" ]' "$(cat "$TMPBASE/forge.log" 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
