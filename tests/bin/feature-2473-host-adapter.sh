#!/usr/bin/env bash
# tests/bin/feature-2473-host-adapter.sh
# Tests: bin/github-issues/lib/host-adapter.sh
# Tags: TL2, bin, migrate, gitlab, forge, scope:issue-specific
# Issue #2473: /migrate-issues creates, closes and comments on issues through host-adapter.sh
# (hia_issue_create / hia_issue_close / hia_issue_comment), which sends a gitlab origin to glab
# (comment = issue note) and a github origin to gh, never both, passing title, body, labels,
# issue number and --repo through. Sourced from the target repo's cwd, the host comes from origin.
# The migration scripts (migrate-todo.sh / migrate-history.sh) are driven once on a gitlab origin.
# TL3 gap: real glab / gh against live forges; here the host CLI is a mock, the other a failing stub.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE
export HIA_T_LOG="$TMPBASE"

ADAPTER="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/host-adapter.sh"
MIG="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration"

# Extensionless bash stubs (bash-to-bash lookup works on Windows too), one PATH dir per host:
# <host>-bin holds the host's CLI as a mock and the other host's CLI as a stub that logs to
# forbidden.log and exits 97. The mock appends "$*" to <tool>.log, stores the latest call's argv
# one element per file in <tool>.args/NNN, and copies a --body-file at call time to <tool>.bodycopy.
mock_tool() { # mock_tool <dir> <tool>
  cat >"$1/$2" <<'MOCK'
#!/usr/bin/env bash
t="$(basename "$0")"
printf '%s\n' "$*" >>"$HIA_T_LOG/$t.log"
rm -rf "$HIA_T_LOG/$t.args"
mkdir -p "$HIA_T_LOG/$t.args"
i=0
prev=""
for a in "$@"; do
  i=$((i + 1))
  printf '%s' "$a" >"$HIA_T_LOG/$t.args/$(printf '%03d' "$i")"
  [ "$prev" = --body-file ] && cp "$a" "$HIA_T_LOG/$t.bodycopy"
  prev="$a"
done
case "$*" in *create*) echo "https://example.invalid/o/r/issues/7" ;; esac
exit 0
MOCK
  chmod +x "$1/$2"
}
forbidden_tool() { # forbidden_tool <dir> <tool>
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"%s/forbidden.log"\necho "%s must not be started for this host" >&2\nexit 97\n' "$2" "$TMPBASE" "$2" >"$1/$2"
  chmod +x "$1/$2"
}
GL_BIN="$TMPBASE/gitlab-bin"
GH_BIN="$TMPBASE/github-bin"
mkdir -p "$GL_BIN" "$GH_BIN"
mock_tool "$GL_BIN" glab
forbidden_tool "$GL_BIN" gh
mock_tool "$GH_BIN" gh
forbidden_tool "$GH_BIN" glab
ORIG_PATH="$PATH"

fx_repo() {
  local d="$TMPBASE/$1"
  mkdir -p "$d"
  harness_git_init "$d"
  git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}
R_GL="$(fx_repo gitlab git@gitlab.com:o/r.git)"
R_GH="$(fx_repo github https://github.com/o/r.git)"
BODY_FILE="$TMPBASE/body dir/body.md"
mkdir -p "$TMPBASE/body dir"
printf "line one\nline two with 'quotes' & spaces\n" >"$BODY_FILE"

reset_logs() {
  rm -rf "$TMPBASE/gh.log" "$TMPBASE/glab.log" "$TMPBASE/forbidden.log" \
    "$TMPBASE/gh.args" "$TMPBASE/glab.args" "$TMPBASE/gh.bodycopy" "$TMPBASE/glab.bodycopy"
}

# drive_one <repo> <bin-dir> <fn> [args...] — one adapter call in <repo> with fresh logs, the
# host's PATH dir first; sets DRIVE_RC.
drive_one() {
  local repo="$1" bin="$2"
  shift 2
  reset_logs
  (
    cd "$repo" || exit 90
    PATH="$bin:$ORIG_PATH"
    # shellcheck source=/dev/null
    . "$ADAPTER" || exit 91
    "$@" >/dev/null
  ) 2>"$TMPBASE/drive.err"
  DRIVE_RC=$?
}
log_of() { cat "$TMPBASE/$1.log" 2>/dev/null; }

# load_argv <tool> — the latest call's argv into ARGV, each element byte-exact.
load_argv() {
  local f v
  ARGV=()
  for f in "$TMPBASE/$1.args"/*; do
    [ -f "$f" ] || continue
    v="$(cat "$f"; printf x)"
    ARGV+=("${v%x}")
  done
}
# flag_val <flag> — the element after the first <flag> in ARGV (exit 1 when absent).
flag_val() {
  local i
  for ((i = 0; i < ${#ARGV[@]} - 1; i++)); do
    [ "${ARGV[$i]}" = "$1" ] && { printf '%s' "${ARGV[$((i + 1))]}"; return 0; }
  done
  return 1
}
# flag_all <flag> — every value after <flag> in ARGV, space-joined in call order.
flag_all() {
  local i out=""
  for ((i = 0; i < ${#ARGV[@]} - 1; i++)); do
    [ "${ARGV[$i]}" = "$1" ] && out="$out${out:+ }${ARGV[$((i + 1))]}"
  done
  printf '%s' "$out"
}
has_arg() { local a; for a in "${ARGV[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
argv_dump() { local a out=""; for a in "${ARGV[@]}"; do out="$out[$a]"; done; printf '%s' "$out"; }
# verdict <label> <ok:0|1> — pass/fail with the call's argv and logs as fail detail.
verdict() {
  if [ "$2" = 1 ]; then
    pass "$1"
  else
    fail "$1" "rc=$DRIVE_RC argv=$(argv_dump) forbidden=[$(log_of forbidden)] err=[$(cat "$TMPBASE/drive.err" 2>/dev/null)]"
  fi
}

# check_host <label> <repo> <bin-dir> <tool> <comment-subcommand> — each of the three calls
# succeeds, reaches <tool> with its own subcommand, and starts no other host's CLI.
check_host() {
  local label="$1" repo="$2" bin="$3" tool="$4" note="$5" row fn want
  for row in "hia_issue_create:issue create" "hia_issue_close:issue close" "hia_issue_comment:$note"; do
    fn="${row%%:*}"
    want="${row#*:}"
    case "$fn" in
      hia_issue_create) drive_one "$repo" "$bin" "$fn" o/r "migrated title" "migrated body" ;;
      hia_issue_close) drive_one "$repo" "$bin" "$fn" o/r 7 ;;
      hia_issue_comment) drive_one "$repo" "$bin" "$fn" o/r 7 "sentinel comment" ;;
    esac
    if [ "$DRIVE_RC" = "0" ] && log_of "$tool" | grep -q "$want" && [ -z "$(log_of forbidden)" ]; then
      pass "$label: $fn calls only $tool ($want)"
    else
      fail "$label: $fn calls only $tool ($want)" "rc=$DRIVE_RC $tool log=[$(log_of "$tool")] forbidden=[$(log_of forbidden)] err=[$(cat "$TMPBASE/drive.err")]"
    fi
  done
}

case_begin "HIA-gitlab-goes-to-glab" "bin/github-issues/lib/host-adapter.sh"
if [ ! -f "$ADAPTER" ]; then
  fail "HIA-gitlab-goes-to-glab" "bin/github-issues/lib/host-adapter.sh does not exist"
else
  check_host gitlab "$R_GL" "$GL_BIN" glab 'issue note'
fi
case_end

case_begin "HIA-github-goes-to-gh" "bin/github-issues/lib/host-adapter.sh"
if [ ! -f "$ADAPTER" ]; then
  fail "HIA-github-goes-to-gh" "bin/github-issues/lib/host-adapter.sh does not exist"
else
  check_host github "$R_GH" "$GH_BIN" gh 'issue comment'
fi
case_end

case_begin "HIA-gitlab-argv-passthrough" "bin/github-issues/lib/host-adapter.sh"
BODY_TEXT="$(cat "$BODY_FILE")"
drive_one "$R_GL" "$GL_BIN" hia_issue_create o/r "migrated title" --body-file "$BODY_FILE" type:task status:migrated
load_argv glab
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[0]-} ${ARGV[1]-}" = "issue create" ] && [ "$(flag_val --title)" = "migrated title" ] &&
  [ "$(flag_val --description)" = "$BODY_TEXT" ] && [ "$(flag_all --label)" = "type:task status:migrated" ] &&
  [ "$(flag_val --repo)" = o/r ] && has_arg --yes && [ -z "$(log_of forbidden)" ] && ok=1
verdict "gitlab: hia_issue_create --body-file passes title, the file's text as --description, both labels and --repo" "$ok"
drive_one "$R_GL" "$GL_BIN" hia_issue_create o/r "migrated title" "migrated body"
load_argv glab
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$(flag_val --description)" = "migrated body" ] && [ -z "$(flag_all --label)" ] && ok=1
verdict "gitlab: hia_issue_create with an inline body passes it as --description and no label" "$ok"
drive_one "$R_GL" "$GL_BIN" hia_issue_close o/r 7
load_argv glab
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[*]:0:3}" = "issue close 7" ] && [ "$(flag_val --repo)" = o/r ] && ok=1
verdict "gitlab: hia_issue_close passes the issue number and --repo" "$ok"
drive_one "$R_GL" "$GL_BIN" hia_issue_comment o/r 7 "sentinel comment"
load_argv glab
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[*]:0:3}" = "issue note 7" ] && [ "$(flag_val --message)" = "sentinel comment" ] &&
  [ "$(flag_val --repo)" = o/r ] && ok=1
verdict "gitlab: hia_issue_comment passes the issue number, the body as --message and --repo" "$ok"
case_end

case_begin "HIA-github-argv-passthrough" "bin/github-issues/lib/host-adapter.sh"
drive_one "$R_GH" "$GH_BIN" hia_issue_create o/r "migrated title" --body-file "$BODY_FILE" type:task status:migrated
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[0]-} ${ARGV[1]-}" = "issue create" ] && [ "$(flag_val --title)" = "migrated title" ] &&
  flag_val --body-file >/dev/null && cmp -s "$BODY_FILE" "$TMPBASE/gh.bodycopy" &&
  [ "$(flag_all --label)" = "type:task status:migrated" ] && [ "$(flag_val --repo)" = o/r ] &&
  [ -z "$(log_of forbidden)" ] && ok=1
verdict "github: hia_issue_create --body-file hands gh a readable file with the body, the title, both labels and --repo" "$ok"
drive_one "$R_GH" "$GH_BIN" hia_issue_create o/r "migrated title" "migrated body"
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$(flag_val --body)" = "migrated body" ] && ! has_arg --body-file && ok=1
verdict "github: hia_issue_create with an inline body passes it as --body" "$ok"
drive_one "$R_GH" "$GH_BIN" hia_issue_close o/r 7
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[*]:0:3}" = "issue close 7" ] && [ "$(flag_val --reason)" = completed ] &&
  [ "$(flag_val --repo)" = o/r ] && ok=1
verdict "github: hia_issue_close passes the issue number, --reason completed and --repo" "$ok"
drive_one "$R_GH" "$GH_BIN" hia_issue_comment o/r 7 "sentinel comment"
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "${ARGV[*]:0:3}" = "issue comment 7" ] && [ "$(flag_val --body)" = "sentinel comment" ] &&
  [ "$(flag_val --repo)" = o/r ] && ok=1
verdict "github: hia_issue_comment passes the issue number, the body as --body and --repo" "$ok"
case_end

# The migration scripts /migrate-issues runs, on a gitlab origin: glab creates (and, for history,
# closes) the issue in origin's project; gh is never started. One canary entry each; needs jq.
case_begin "HIA-migrate-scripts-gitlab-wiring" "bin/github-issues/lib/host-adapter.sh"
if ! command -v jq >/dev/null 2>&1; then
  skip "migration scripts on a gitlab origin: jq not on PATH (the migration state needs it)"
else
  R_MIG="$(fx_repo x git@gitlab.com:grp/x.git)"
  mkdir -p "$R_MIG/docs"
  printf '# Tasks\n\n## Port the parser\n\nbody line\n' >"$R_MIG/docs/todo.md"
  printf '# History\n\n### FEATURE: port the parser (2026-01-02, a1a1a1a, #1)\n\nbody line\n' >"$R_MIG/docs/history.md"
  for script in migrate-todo.sh migrate-history.sh; do
    reset_logs
    (cd "$TMPBASE" && PATH="$GL_BIN:$ORIG_PATH" run_with_timeout 60 bash "$MIG/$script" "$R_MIG" --canary 1) >"$TMPBASE/mig.out" 2>&1
    MIG_RC=$?
    ok=0
    [ "$MIG_RC" = 0 ] && log_of glab | grep -q '^issue create --title ' && log_of glab | grep -q -- '--yes --repo grp/x$' && [ -z "$(log_of forbidden)" ] && ok=1
    if [ "$script" = migrate-history.sh ] && ! log_of glab | grep -qx 'issue close 7 --repo grp/x'; then ok=0; fi
    if [ "$ok" = 1 ]; then
      pass "$script on a gitlab origin: glab issue create$([ "$script" = migrate-history.sh ] && echo ' + close') in grp/x, gh never started"
    else
      fail "$script on a gitlab origin" "rc=$MIG_RC glab=[$(log_of glab | tr '\n' '|')] forbidden=[$(log_of forbidden)] out=$(tail -c 300 "$TMPBASE/mig.out")"
    fi
  done
fi
case_end

# Read stubs: log argv like mock_tool, print <tool>.out when present and exit with <tool>.rc (default 0).
read_tool() { # read_tool <dir> <tool>
  cat >"$1/$2" <<'READ'
#!/usr/bin/env bash
t="$(basename "$0")"
printf '%s\n' "$*" >>"$HIA_T_LOG/$t.log"
rm -rf "$HIA_T_LOG/$t.args"
mkdir -p "$HIA_T_LOG/$t.args"
i=0
for a in "$@"; do i=$((i + 1)); printf '%s' "$a" >"$HIA_T_LOG/$t.args/$(printf '%03d' "$i")"; done
[ -f "$HIA_T_LOG/$t.out" ] && cat "$HIA_T_LOG/$t.out"
exit "$(cat "$HIA_T_LOG/$t.rc" 2>/dev/null || echo 0)"
READ
  chmod +x "$1/$2"
}
RGL_BIN="$TMPBASE/read-gitlab-bin"
RGH_BIN="$TMPBASE/read-github-bin"
mkdir -p "$RGL_BIN" "$RGH_BIN"
read_tool "$RGL_BIN" glab
forbidden_tool "$RGL_BIN" gh
read_tool "$RGH_BIN" gh
forbidden_tool "$RGH_BIN" glab

# drive_read <repo> <bin-dir> <tool> <out-text> <rc> <fn> [args...] — sets READ_OUT / DRIVE_RC.
drive_read() {
  local repo="$1" bin="$2" tool="$3" out="$4" rc="$5"
  shift 5
  reset_logs
  printf '%s' "$out" >"$TMPBASE/$tool.out"
  printf '%s' "$rc" >"$TMPBASE/$tool.rc"
  READ_OUT="$(
    cd "$repo" || exit 90
    PATH="$bin:$ORIG_PATH"
    # shellcheck source=/dev/null
    . "$ADAPTER" || exit 91
    "$@"
  )"
  DRIVE_RC=$?
  rm -f "$TMPBASE/$tool.out" "$TMPBASE/$tool.rc"
}
NL=$'\n'

case_begin "HIA-github-reads" "bin/github-issues/lib/host-adapter.sh"
drive_read "$R_GH" "$RGH_BIN" gh "3${NL}5${NL}" 0 hia_issue_closed_numbers
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$READ_OUT" = "3${NL}5" ] && [ "${ARGV[*]:0:2}" = "issue list" ] &&
  [ "$(flag_val --state)" = closed ] && [ "$(flag_val --limit)" = 1000 ] && [ "$(flag_val --json)" = number ] &&
  [ "$(flag_val --jq)" = '.[].number' ] && [ -z "$(log_of forbidden)" ] && ok=1
verdict "github: hia_issue_closed_numbers lists closed numbers one per line (default limit 1000)" "$ok"
drive_read "$R_GH" "$RGH_BIN" gh "4${NL}" 0 hia_issue_closed_numbers 7
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$(flag_val --limit)" = 7 ] && ok=1
verdict "github: hia_issue_closed_numbers passes the limit through" "$ok"
drive_read "$R_GH" "$RGH_BIN" gh "commit abc1234 merged${NL}" 0 hia_issue_comment_first_match 12 '^commit "x"'
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$READ_OUT" = "commit abc1234 merged" ] && [ "${ARGV[*]:0:3}" = "issue view 12" ] &&
  [ "$(flag_val --json)" = comments ] && [ "$(flag_val --jq)" = '[.comments[].body | select(test("^commit \"x\""))] | first // ""' ] &&
  [ -z "$(log_of forbidden)" ] && ok=1
verdict "github: hia_issue_comment_first_match views the issue's comments with the regex escaped into --jq" "$ok"
case_end

case_begin "HIA-github-read-failure" "bin/github-issues/lib/host-adapter.sh"
for fn in "hia_issue_closed_numbers" "hia_issue_comment_first_match 12 ^commit"; do
  # shellcheck disable=SC2086
  drive_read "$R_GH" "$RGH_BIN" gh "" 1 $fn
  ok=0
  [ "$DRIVE_RC" != 0 ] && [ -z "$READ_OUT" ] && ok=1
  verdict "github: ${fn%% *} returns non-zero when gh fails" "$ok"
done
case_end

case_begin "HIA-gitlab-reads" "bin/github-issues/lib/host-adapter.sh"
if ! command -v jq >/dev/null 2>&1; then
  skip "gitlab reads: jq not on PATH"
else
  drive_read "$R_GL" "$RGL_BIN" glab '[{"iid":3},{"iid":5}][{"iid":9}]' 0 hia_issue_closed_numbers
  load_argv glab
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ "$(printf '%s' "$READ_OUT" | tr -d '\r')" = "3${NL}5${NL}9" ] &&
    [ "${ARGV[*]}" = 'api --paginate projects/:id/issues?state=closed&per_page=100' ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "gitlab: hia_issue_closed_numbers flattens every paginated page into iids" "$ok"
  drive_read "$R_GL" "$RGL_BIN" glab '[{"iid":3},{"iid":5}][{"iid":9}]' 0 hia_issue_closed_numbers 2
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ "$(printf '%s' "$READ_OUT" | tr -d '\r')" = "3${NL}5" ] && ok=1
  verdict "gitlab: hia_issue_closed_numbers stops at the limit" "$ok"
  NOTES='[{"body":"no"},{"body":"commit abc1234 merged"}][{"body":"commit def5678"}]'
  drive_read "$R_GL" "$RGL_BIN" glab "$NOTES" 0 hia_issue_comment_first_match 12 '^commit '
  load_argv glab
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ "$(printf '%s' "$READ_OUT" | tr -d '\r')" = "commit abc1234 merged" ] &&
    [ "${ARGV[*]}" = 'api --paginate projects/:id/issues/12/notes?per_page=100' ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "gitlab: hia_issue_comment_first_match returns the first matching note body" "$ok"
  drive_read "$R_GL" "$RGL_BIN" glab "$NOTES" 0 hia_issue_comment_first_match 12 '^nomatch'
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ -z "$(printf '%s' "$READ_OUT" | tr -d '\r')" ] && ok=1
  verdict "gitlab: hia_issue_comment_first_match is empty with rc 0 when no note matches" "$ok"
fi
case_end

case_begin "HIA-gitlab-read-failure" "bin/github-issues/lib/host-adapter.sh"
for fn in "hia_issue_closed_numbers" "hia_issue_comment_first_match 12 ^commit"; do
  # shellcheck disable=SC2086
  drive_read "$R_GL" "$RGL_BIN" glab '[{"iid":3}]' 1 $fn
  ok=0
  [ "$DRIVE_RC" != 0 ] && [ -z "$READ_OUT" ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "gitlab: ${fn%% *} returns non-zero and prints nothing when glab fails" "$ok"
done
case_end

# hia_issue_field / hia_issue_closing_merge_shas: the reads backfill-commit-comments.sh needs.
case_begin "HIA-github-issue-field" "bin/github-issues/lib/host-adapter.sh"
for field in body title; do
  drive_read "$R_GH" "$RGH_BIN" gh "the $field${NL}" 0 hia_issue_field 12 "$field"
  load_argv gh
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ "$READ_OUT" = "the $field" ] && [ "${ARGV[*]:0:3}" = "issue view 12" ] &&
    [ "$(flag_val --json)" = "$field" ] && [ "$(flag_val --jq)" = ".$field // \"\"" ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "github: hia_issue_field 12 $field views --json $field and prints it" "$ok"
done
case_end
case_begin "HIA-gitlab-issue-field" "bin/github-issues/lib/host-adapter.sh"
if ! command -v jq >/dev/null 2>&1; then
  skip "gitlab issue field: jq not on PATH"
else
  ISSUE='{"iid":12,"title":"the title","description":"the description","body":"not this"}'
  for row in "body:the description" "title:the title"; do
    drive_read "$R_GL" "$RGL_BIN" glab "$ISSUE" 0 hia_issue_field 12 "${row%%:*}"
    load_argv glab
    ok=0
    [ "$DRIVE_RC" = 0 ] && [ "$(printf '%s' "$READ_OUT" | tr -d '\r')" = "${row#*:}" ] &&
      [ "${ARGV[*]}" = 'api projects/:id/issues/12' ] && [ -z "$(log_of forbidden)" ] && ok=1
    verdict "gitlab: hia_issue_field 12 ${row%%:*} reads ${row#*:} from glab api (body = description)" "$ok"
  done
  drive_read "$R_GL" "$RGL_BIN" glab '{"iid":12,"title":"t","description":null}' 0 hia_issue_field 12 body
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ -z "$(printf '%s' "$READ_OUT" | tr -d '\r')" ] && ok=1
  verdict "gitlab: hia_issue_field body is empty with rc 0 when the description is null" "$ok"
fi
case_end
case_begin "HIA-issue-field-refusals" "bin/github-issues/lib/host-adapter.sh"
for host in GH GL; do
  repo_v="R_$host"
  bin_v="R${host}_BIN"
  tool=gh fail_out=""
  # glab's output is captured before jq, so a failing glab may print and still yield nothing.
  [ "$host" = GL ] && tool=glab fail_out='{"title":"x"}'
  drive_read "${!repo_v}" "${!bin_v}" "$tool" "" 0 hia_issue_field 12 labels
  ok=0
  [ "$DRIVE_RC" = 2 ] && [ -z "$READ_OUT" ] && [ -z "$(log_of "$tool")" ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "$tool: hia_issue_field with an unknown field returns 2 and starts no CLI" "$ok"
  drive_read "${!repo_v}" "${!bin_v}" "$tool" "$fail_out" 1 hia_issue_field 12 title
  ok=0
  [ "$DRIVE_RC" != 0 ] && [ -z "$READ_OUT" ] && ok=1
  verdict "$tool: hia_issue_field returns non-zero and prints nothing when $tool fails" "$ok"
  drive_read "${!repo_v}" "${!bin_v}" "$tool" "" 0 hia_issue_field 12
  ok=0
  [ "$DRIVE_RC" != 0 ] && [ -z "$(log_of "$tool")" ] && ok=1
  verdict "$tool: hia_issue_field without a field fails before any CLI" "$ok"
done
case_end

case_begin "HIA-github-closing-merge-shas" "bin/github-issues/lib/host-adapter.sh"
drive_read "$R_GH" "$RGH_BIN" gh "aaa111${NL}bbb222${NL}" 0 hia_issue_closing_merge_shas 12
load_argv gh
ok=0
[ "$DRIVE_RC" = 0 ] && [ "$READ_OUT" = "aaa111${NL}bbb222" ] && [ "${ARGV[*]:0:3}" = "issue view 12" ] &&
  [ "$(flag_val --json)" = closedByPullRequestsReferences ] &&
  [ "$(flag_val --jq)" = '.closedByPullRequestsReferences[] | select(.mergeCommit != null) | .mergeCommit.oid' ] &&
  [ -z "$(log_of forbidden)" ] && ok=1
verdict "github: hia_issue_closing_merge_shas reads the merged closing PRs' merge commits" "$ok"
drive_read "$R_GH" "$RGH_BIN" gh "" 1 hia_issue_closing_merge_shas 12
ok=0
[ "$DRIVE_RC" != 0 ] && [ -z "$READ_OUT" ] && ok=1
verdict "github: hia_issue_closing_merge_shas returns non-zero when gh fails" "$ok"
case_end
case_begin "HIA-gitlab-closing-merge-shas" "bin/github-issues/lib/host-adapter.sh"
if ! command -v jq >/dev/null 2>&1; then
  skip "gitlab closing merge shas: jq not on PATH"
else
  CLOSED_BY='[{"state":"merged","merge_commit_sha":"aaa111"},{"state":"opened","merge_commit_sha":null},{"state":"merged","merge_commit_sha":null,"squash_commit_sha":"bbb222"},{"state":"closed","merge_commit_sha":"ccc333"}]'
  drive_read "$R_GL" "$RGL_BIN" glab "$CLOSED_BY" 0 hia_issue_closing_merge_shas 12
  load_argv glab
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ "$(printf '%s' "$READ_OUT" | tr -d '\r')" = "aaa111${NL}bbb222" ] &&
    [ "${ARGV[*]}" = 'api projects/:id/issues/12/closed_by' ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "gitlab: hia_issue_closing_merge_shas keeps merged MRs only (merge, else squash sha)" "$ok"
  drive_read "$R_GL" "$RGL_BIN" glab '[]' 0 hia_issue_closing_merge_shas 12
  ok=0
  [ "$DRIVE_RC" = 0 ] && [ -z "$(printf '%s' "$READ_OUT" | tr -d '\r')" ] && ok=1
  verdict "gitlab: hia_issue_closing_merge_shas is empty with rc 0 when no MR closed the issue" "$ok"
  drive_read "$R_GL" "$RGL_BIN" glab "$CLOSED_BY" 1 hia_issue_closing_merge_shas 12
  ok=0
  [ "$DRIVE_RC" != 0 ] && [ -z "$READ_OUT" ] && [ -z "$(log_of forbidden)" ] && ok=1
  verdict "gitlab: hia_issue_closing_merge_shas returns non-zero and prints nothing when glab fails" "$ok"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
