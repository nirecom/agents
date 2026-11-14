#!/usr/bin/env bash
# Tests: bin/lib/native-path.sh, bin/github-issues/issue-create.sh, bin/github-issues/issue-body-append.sh, bin/github-issues/reopen-with-update.sh, bin/lib/github-contents-write.sh, bin/lib/github-git-data-write.sh, bin/github-issues/migration/migrate-history.sh, bin/github-issues/migration/migrate-todo.sh
# Tags: github, gh, windows-path, msys, scope:issue-specific, TL1, TL2
# Issue #2221 Change 3: under MSYS_NO_PATHCONV=1 native gh.exe cannot read an MSYS file path; native_path
# converts once at the gh boundary (cygpath -m when present, else or on failure unchanged, `-` untouched).
# A recording gh stub shows what issue-create.sh and issue-body-append.sh actually pass as --body-file.
# TL3 gap (what this test does NOT catch):
# - The real gh.exe opening the converted --body-file/--input path (the stub only records argv).
# Closest-to-action mitigation: none — no check-verification-gate category covers gh; check by hand on Git Bash.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

GNP_TMP="$(make_tmp)"
readonly GNP_TMP
trap 'rm -rf "$GNP_TMP"' EXIT
harness_isolate "$GNP_TMP"
export HOME="$GNP_TMP/home"
export USERPROFILE="$HOME"
mkdir -p "$HOME"
unset CLAUDE_CODE_SESSION_ID CLAUDECODE REPO_OVERRIDE 2>/dev/null || true

LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/native-path.sh"
EMPTY_BIN="$GNP_TMP/empty-bin"
FAILING_BIN="$GNP_TMP/failing-cygpath-bin"
mkdir -p "$EMPTY_BIN" "$FAILING_BIN"
# A cygpath that always fails and records each call, so the fallback and the `-` bypass are visible.
printf '#!/bin/sh\necho "$*" >> "%s/cygpath-calls"\nexit 1\n' "$GNP_TMP" > "$FAILING_BIN/cygpath"
chmod +x "$FAILING_BIN/cygpath"
HAVE_CYGPATH=0
command -v cygpath >/dev/null 2>&1 && HAVE_CYGPATH=1

# np_call <PATH> <input> — prints native_path's output; exit 99 when the lib cannot be sourced.
np_call() {
  run_with_timeout 10 env PATH="$1" "$BASH" -c '. "$1" || exit 99; native_path "$2"' _ "$LIB" "$2"
}

# np_row <label> <PATH> <input> <mode> <want> — mode: eq (exact) or re (extended regex).
np_row() {
  local label="$1" p="$2" in="$3" mode="$4" want="$5" got rc ok=0
  got="$(np_call "$p" "$in" 2>"$GNP_TMP/np.err")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    case "$mode" in
      eq) [ "$got" = "$want" ] && ok=1 ;;
      re) printf '%s' "$got" | grep -qE "$want" && ok=1 ;;
    esac
  fi
  if [ "$ok" -eq 1 ]; then
    pass "native_path[$label] '$in' -> '$got'"
  else
    fail "native_path[$label] '$in'" "rc=$rc got='$got' want($mode)='$want' err=$(head -c 200 "$GNP_TMP/np.err")"
  fi
}

case_begin "native-path-table" "bin/lib/native-path.sh"
if [ "$HAVE_CYGPATH" -eq 1 ]; then
  np_row "cygpath dash" "$PATH" "-" eq "-"
  np_row "cygpath relative" "$PATH" "body.md" eq "body.md"
  np_row "cygpath dash-led relative" "$PATH" "-x.md" eq "-x.md"
  np_row "cygpath msys abs" "$PATH" "/tmp/x" re '^[A-Za-z]:/.*/x$'
  np_row "cygpath mixed abs" "$PATH" "C:/x" eq "C:/x"
  np_row "cygpath space" "$PATH" "/tmp/a b/c.md" re '^[A-Za-z]:/.*/a b/c\.md$'
else
  skip "native_path with a real cygpath: not on this host (TL3 gap: Windows Git Bash only)"
fi
for _in in "-" "body.md" "/tmp/x" "C:/x" "/tmp/a b/c.md"; do
  np_row "no cygpath" "$EMPTY_BIN" "$_in" eq "$_in"
done
rm -f "$GNP_TMP/cygpath-calls"
for _in in "/tmp/x" "/tmp/a b/c.md"; do
  np_row "cygpath fails" "$FAILING_BIN" "$_in" eq "$_in"
done
if [ -s "$GNP_TMP/cygpath-calls" ]; then
  pass "native_path: a failing cygpath was really consulted before the fallback"
else
  fail "native_path: the failing cygpath was never called" "the fallback rows above passed without exercising cygpath"
fi
rm -f "$GNP_TMP/cygpath-calls"
np_row "dash never converted" "$FAILING_BIN" "-" eq "-"
if [ "$(np_call "$FAILING_BIN" "-" 2>/dev/null)" = "-" ] && [ ! -e "$GNP_TMP/cygpath-calls" ]; then
  pass "native_path: '-' (stdin) never reaches cygpath"
else
  fail "native_path: '-' was passed to cygpath" "$(cat "$GNP_TMP/cygpath-calls")"
fi
# A dash-led path other than `-` is a path, not a cygpath option: it must follow `--`.
np_row "no cygpath dash-led" "$EMPTY_BIN" "-x.md" eq "-x.md"
rm -f "$GNP_TMP/cygpath-calls"
np_row "cygpath fails dash-led" "$FAILING_BIN" "-x.md" eq "-x.md"
if grep -qE -- '(^| )-- -x\.md$' "$GNP_TMP/cygpath-calls" 2>/dev/null; then
  pass "native_path: '-x.md' reaches cygpath only after '--', never as an option"
else
  fail "native_path: '-x.md' not passed after '--'" "calls=[$(cat "$GNP_TMP/cygpath-calls" 2>/dev/null)]"
fi
case_end

# ---------------------------------------------------------------- gh integration
# A checkout copy whose is-github-dotcom-remote says non-GitHub (skips Phase 0a label repair).
# The copy holds tracked files only, so the lib under test is copied in when present.
CO="$GNP_TMP/co"
script_checkout_fixture_copy "$CO" bin hooks >/dev/null 2>&1 || fail "fixture" "checkout copy failed"
[ -f "$LIB" ] && cp "$LIB" "$CO/bin/lib/native-path.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CO/bin/is-github-dotcom-remote"
chmod +x "$CO/bin/is-github-dotcom-remote"
: > "$CO/.private-info-allowlist"
: > "$CO/.private-info-blocklist"
STUB_BIN="$GNP_TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  auth\ status*) echo "scopes: 'project', 'repo'"; exit 0 ;;
  issue\ view*) echo "ORIGINAL body"; exit 0 ;;
esac
printf '%s\n' "$@" > "$GNP_GH_LOG"
case "$*" in issue\ create*) echo "https://github.com/example/repo/issues/7" ;; esac
exit 0
GH
chmod +x "$STUB_BIN/gh"
export GNP_GH_LOG="$GNP_TMP/gh-args"
mkdir -p "$GNP_TMP/body dir"
BODY_FILE="$GNP_TMP/body dir/body.md"
printf 'ordinary body text\n' > "$BODY_FILE"

# is_abs_path <p> — POSIX absolute or drive-letter absolute (gh resolves a relative one against its cwd).
is_abs_path() { case "$1" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;; esac; return 1; }

# recorded_body_file — the argument after --body-file in the last recorded gh call.
recorded_body_file() { awk 'prev == "--body-file" { print; exit } { prev = $0 }' "$GNP_GH_LOG" 2>/dev/null; }

# gh_check <label> <rc> <input path> — the recorded --body-file is native (cygpath host) or unchanged.
gh_check() {
  local label="$1" rc="$2" in="$3" got
  if [ "$#" -ge 4 ]; then got="$4"; else got="$(recorded_body_file)"; fi
  if [ "$HAVE_CYGPATH" -eq 1 ]; then
    if [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -qE '^[A-Za-z]:/'; then
      pass "$label: --body-file reaches gh in native form ($got)"
    else
      fail "$label: --body-file not native" "rc=$rc got='$got' (want ^[A-Za-z]:/)"
    fi
  elif [ "$rc" -eq 0 ] && [ "$got" = "$in" ]; then
    pass "$label: without cygpath --body-file is passed unchanged"
  else
    fail "$label: without cygpath" "rc=$rc got='$got' want='$in'"
  fi
}

case_begin "issue-create-body-file" "bin/github-issues/issue-create.sh"
rm -f "$GNP_GH_LOG"
cd "$GNP_TMP" || exit 1
PATH="$STUB_BIN:$PATH" MSYS_NO_PATHCONV=1 ISSUE_CREATE_SKIP_SCHEMA=1 run_with_timeout 60 bash "$CO/bin/github-issues/issue-create.sh" \
  --title "ordinary title" --body-file "$BODY_FILE" >"$GNP_TMP/ic.out" 2>"$GNP_TMP/ic.err"
IC_RC=$?
[ -s "$GNP_GH_LOG" ] || fail "issue-create: gh was not reached" "rc=$IC_RC err=$(head -c 400 "$GNP_TMP/ic.err")"
gh_check "issue-create" "$IC_RC" "$BODY_FILE"
case_end

case_begin "issue-body-append-body-file" "bin/github-issues/issue-body-append.sh"
# The wrapper's <user>-block guard (#2940) reads the old issue state from a node child that spawns
# `gh` by name, which the bash stub above cannot answer. This case therefore uses the scripted stub
# (tests/lib/gh-scripted-stub.js: a bash `gh` plus, on Windows, a gh.exe the preload turns into the
# stub); the old body has no <user> block, so the write goes ahead and its --body-file is logged.
SCR_OUT="$(node "$(cygpath -m "$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-scripted-stub.js" 2>/dev/null || echo "$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-scripted-stub.js")" setup "$(cygpath -m "$GNP_TMP/scr" 2>/dev/null || echo "$GNP_TMP/scr")")"
SCR_BIN="${SCR_OUT%%$'\n'*}"; SCR_PRELOAD="${SCR_OUT#*$'\n'}"
command -v cygpath >/dev/null 2>&1 && SCR_BIN="$(cygpath -u "$SCR_BIN")"
printf '{"rules":[{"match":"^auth status","stdout":"scopes: project, repo"},{"match":"^issue view","stdout":"ORIGINAL body"},{"match":"api graphql","stdout":{"data":{"repository":{"issue":{"id":"I_7","title":"ordinary title","body":"ORIGINAL body","comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}}],"fallback":{"exit":0}}\n' > "$GNP_TMP/scr-spec.json"
PATH="$SCR_BIN:$PATH" MSYS_NO_PATHCONV=1 NODE_OPTIONS="--require \"$SCR_PRELOAD\"" \
  F2940_GH_SPEC="$(cygpath -m "$GNP_TMP/scr-spec.json" 2>/dev/null || echo "$GNP_TMP/scr-spec.json")" F2940_GH_LOG="$(cygpath -m "$GNP_TMP/scr-calls.jsonl" 2>/dev/null || echo "$GNP_TMP/scr-calls.jsonl")" \
  run_with_timeout 60 bash "$CO/bin/github-issues/issue-body-append.sh" \
  --issue 7 --note "ordinary note" >"$GNP_TMP/iba.out" 2>"$GNP_TMP/iba.err"
IBA_RC=$?
IBA_IN="$(node -e "const l=require('fs').readFileSync(process.argv[1],'utf8').split('\n').filter(Boolean).map(JSON.parse);let v='';for(const r of l){const i=r.args.indexOf('--body-file');if(i>=0)v=r.args[i+1]}console.log(v)" "$(cygpath -m "$GNP_TMP/scr-calls.jsonl" 2>/dev/null || echo "$GNP_TMP/scr-calls.jsonl")" 2>/dev/null)"
# The stub reads the --body-file when gh is called (null when the path does not exist for gh), so a
# wrong path that merely looks native (C:/...) is caught here, not by the path shape alone.
IBA_BODY="$(node -e "const l=require('fs').readFileSync(process.argv[1],'utf8').split('\n').filter(Boolean).map(JSON.parse);let v=null;for(const r of l){if(r.args.includes('--body-file'))v=r.bodyFile}process.stdout.write(v===null?'<<UNREADABLE>>':v)" "$(cygpath -m "$GNP_TMP/scr-calls.jsonl" 2>/dev/null || echo "$GNP_TMP/scr-calls.jsonl")" 2>/dev/null)"
if [ "$IBA_RC" -eq 0 ] && printf '%s' "$IBA_BODY" | grep -q 'ORIGINAL body' && printf '%s' "$IBA_BODY" | grep -q 'ordinary note'; then
  pass "issue-body-append: gh could read the --body-file and it holds the original body plus the note"
else
  fail "issue-body-append: --body-file content" "rc=$IBA_RC path='$IBA_IN' body='$(printf '%s' "$IBA_BODY" | head -c 300)' (want ORIGINAL body + ordinary note)"
fi
if [ "$HAVE_CYGPATH" -eq 1 ]; then
  gh_check "issue-body-append" "$IBA_RC" "$IBA_IN" "$IBA_IN"
elif [ "$IBA_RC" -eq 0 ] && is_abs_path "$IBA_IN"; then
  pass "issue-body-append: without cygpath the absolute mktemp path is passed as-is ($IBA_IN)"
else
  fail "issue-body-append" "rc=$IBA_RC recorded='$IBA_IN' err=$(head -c 400 "$GNP_TMP/iba.err")"
fi
case_end

# ---------------------------------------------------------------- sibling audit (static)
# Every gh file-path argument of the audited siblings goes through native_path (CPR-ORTH).
case_begin "sibling-gh-file-args" "bin/lib/native-path.sh"
AUDITED="bin/github-issues/issue-create.sh bin/github-issues/issue-body-append.sh
bin/github-issues/reopen-with-update.sh bin/lib/github-contents-write.sh
bin/lib/github-git-data-write.sh bin/github-issues/migration/migrate-history.sh
bin/github-issues/migration/migrate-todo.sh"
for rel in $AUDITED; do
  f="$SCRIPT_CHECKOUT_ROOT/$rel"
  raw="$(grep -cE -- '--(body-file|input) "\$[A-Za-z_{]' "$f" 2>/dev/null)"
  wrapped="$(grep -cE -- '--(body-file|input) "\$\(native_path ' "$f" 2>/dev/null)"
  if [ -f "$f" ] && [ "${raw:-0}" -eq 0 ] && [ "${wrapped:-0}" -ge 1 ] && grep -q 'native-path\.sh' "$f"; then
    pass "$rel: every gh --body-file/--input path goes through native_path"
  else
    fail "$rel" "unwrapped=${raw:-?} wrapped=${wrapped:-?} sources-lib=$(grep -q 'native-path\.sh' "$f" 2>/dev/null && echo y || echo n)"
  fi
done
# Discovery: every bin/ file with a non-comment line invoking `gh ` with --body-file/--input must be
# audited above, so a new gh file-path call site cannot bypass native_path unnoticed.
GH_SCAN="$(cd "$SCRIPT_CHECKOUT_ROOT" && grep -rlE '^[^#]*(^|[^A-Za-z0-9_.-])gh [^#]*--(body-file|input)( |=|$)' bin | sort -u)"
GH_UNAUDITED="$(comm -23 <(printf '%s\n' "$GH_SCAN") <(printf '%s\n' $AUDITED | sort -u))"
if [ -n "$GH_SCAN" ] && [ -z "$GH_UNAUDITED" ]; then
  pass "bin/ scan: all $(printf '%s\n' "$GH_SCAN" | wc -l | tr -d ' ') gh --body-file/--input files are audited"
else
  fail "bin/ scan: gh --body-file/--input call sites outside the audited list" "unaudited=[$GH_UNAUDITED] scanned=[$GH_SCAN]"
fi
case_end

# ---------------------------------------------------------------- #2473 gitlab origin
# /migrate-issues creates and closes issues through host-adapter.sh (hia_issue_create /
# hia_issue_close), so a gitlab origin reaches glab and gh is never started: gh is a stub that
# exits 97 and logs to forbidden.log; the glab mock answers issue create with GitLab issue 42,
# records each call's argv one element per line after an @@call line in glab.argv, and fails the
# subcommand GNP_GL_FAIL names (create or close).
# TL3 gap: a real GitLab project; the labels and the close reason glab really accepts.
GL_BIN="$GNP_TMP/gitlab-bin"
mkdir -p "$GL_BIN"
export GNP_GL_DIR="$GNP_TMP"
cat >"$GL_BIN/glab" <<'GLAB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GNP_GL_DIR/glab.log"
printf '@@call\n' >>"$GNP_GL_DIR/glab.argv"
printf '%s\n' "$@" >>"$GNP_GL_DIR/glab.argv"
case "$*" in
  *"issue create"*) [ "${GNP_GL_FAIL:-}" = create ] && exit 1; echo "https://gitlab.com/grp/proj/-/issues/42" ;;
  *"issue close"*) [ "${GNP_GL_FAIL:-}" = close ] && exit 1 ;;
esac
exit 0
GLAB
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >>"%s/forbidden.log"\necho "gh must not be started for a gitlab origin" >&2\nexit 97\n' "$GNP_TMP" >"$GL_BIN/gh"
chmod +x "$GL_BIN/glab" "$GL_BIN/gh"
MIG="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration"
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
# gl_repo <name> <docs file> <text> — a repo whose origin is the gitlab project grp/<name>, holding one docs file.
gl_repo() {
  local d="$GNP_TMP/$1"
  mkdir -p "$d/docs"
  harness_git_init "$d"
  git -C "$d" remote add origin "git@gitlab.com:grp/$1.git"
  printf '%b' "$3" >"$d/docs/$2"
  printf '%s' "$d"
}
# gl_migrate <script> <repo> [fail] — one canary run of 1 from a neutral cwd with fresh logs, glab
# failing the [fail] subcommand; sets GL_RC.
gl_migrate() {
  rm -f "$GNP_TMP/glab.log" "$GNP_TMP/glab.argv" "$GNP_TMP/forbidden.log"
  (cd "$GNP_TMP" && GNP_GL_FAIL="${3:-}" PATH="$GL_BIN:$PATH" run_with_timeout 60 bash "$MIG/$1" "$2" --canary 1) >"$GNP_TMP/gl.out" 2>&1
  GL_RC=$?
}
gl_log() { cat "$GNP_TMP/$1.log" 2>/dev/null; }
# gl_call <subcommand> — the argv lines of the first recorded `glab issue <subcommand>` call.
gl_call() {
  awk -v want="$1" '
    /^@@call$/ { n = 0; inblk = 0; next }
    { n++ }
    n == 1 { a1 = $0; next }
    n == 2 { inblk = (a1 == "issue" && $0 == want && !done); if (inblk) { done = 1; print a1; print }; next }
    inblk { print }
  ' "$GNP_TMP/glab.argv" 2>/dev/null
}
# flag_vals <short> <long> — on stdin argv lines, the value of each <short> / <long> / <long>=v.
flag_vals() {
  awk -v s="$1" -v l="$2" 'take { print; take = 0; next } $0 == s || $0 == l { take = 1; next } index($0, l "=") == 1 { print substr($0, length(l) + 2) }'
}
# gl_labels — the sorted label set of the first glab issue create (repeated and comma-joined flags).
gl_labels() { gl_call create | flag_vals -l --label | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# gl_state <repo> <jq filter> — the filter over the repo's migration state, compact, CR-free.
gl_state() { jq -c "$2" "$1/.migration-state.json" 2>/dev/null | tr -d '\r'; }
# gl_create_ok <repo> <title> <body first line> <labels> — the create call names origin's project,
# the title, the body and exactly the labels.
gl_create_ok() {
  local proj="grp/$(basename "$1")"
  [ "$(gl_call create | flag_vals -R --repo)" = "$proj" ] &&
    [ "$(gl_call create | flag_vals -t --title)" = "$2" ] &&
    [ "$(gl_call create | flag_vals -d --description | head -1)" = "$3" ] &&
    gl_call create | grep -qx 'body line' &&
    [ "$(gl_labels)" = "$4" ]
}
gl_detail() { echo "rc=$GL_RC create=[$(gl_call create | tr '\n' '|')] close=[$(gl_call close | tr '\n' '|')] forbidden=[$(gl_log forbidden)] state=[$(gl_state "$1" '{todo:.todo.migrated,history:.history.migrated}')] out=$(tail -c 300 "$GNP_TMP/gl.out")"; }
# routes_through <script> <fn...> — every fn is called, and no live line runs gh issue create/close/comment
# (comments and the dry-run echo lines are not calls).
routes_through() {
  local f="$MIG/$1" fn
  shift
  for fn in "$@"; do grep -q "$fn" "$f" || return 1; done
  ! grep -E '^[^#]*gh issue (create|close|comment)' "$f" | grep -vq 'echo '
}

case_begin "migrate-todo-gitlab-goes-to-glab" "bin/github-issues/migration/migrate-todo.sh"
if routes_through migrate-todo.sh hia_issue_create; then
  pass "migrate-todo.sh creates issues through hia_issue_create, never gh issue create"
else
  fail "migrate-todo.sh routing" "hia_issue_create missing or a direct gh issue call remains"
fi
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "migrate-todo on a gitlab origin: jq not on PATH (the migration state needs it)"
else
  R_TODO="$(gl_repo todo-gitlab todo.md '# Tasks\n\n## Port the parser\n\nbody line\n')"
  gl_migrate migrate-todo.sh "$R_TODO"
  if [ "$GL_RC" -eq 0 ] && gl_log glab | grep -q 'issue create' && [ -z "$(gl_log forbidden)" ] && grep -q 'created #42' "$GNP_TMP/gl.out"; then
    pass "migrate-todo on a gitlab origin creates the issue with glab only"
  else
    fail "migrate-todo on a gitlab origin" "$(gl_detail "$R_TODO")"
  fi
  if gl_create_ok "$R_TODO" "Port the parser" "## Port the parser" "type:task"; then
    pass "migrate-todo on a gitlab origin: glab issue create gets origin's project, the title, the body and type:task"
  else
    fail "migrate-todo glab issue create argv" "$(gl_detail "$R_TODO")"
  fi
  if [ "$(gl_state "$R_TODO" '.todo.migrated')" = '[{"entry_id":"t-0001","issue_number":42,"title":"Port the parser"}]' ]; then
    pass "migrate-todo on a gitlab origin: the state records t-0001 as GitLab issue 42"
  else
    fail "migrate-todo state" "$(gl_detail "$R_TODO")"
  fi
fi
case_end

case_begin "migrate-todo-gitlab-create-fails" "bin/github-issues/migration/migrate-todo.sh"
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "migrate-todo create failure on a gitlab origin: jq not on PATH"
else
  R_TODO_F="$(gl_repo todo-gitlab-fail todo.md '# Tasks\n\n## Port the parser\n\nbody line\n')"
  gl_migrate migrate-todo.sh "$R_TODO_F" create
  if [ "$GL_RC" -ne 0 ] && gl_log glab | grep -q 'issue create' && [ -z "$(gl_log forbidden)" ] && [ "$(gl_state "$R_TODO_F" '.todo.migrated | length')" != 1 ]; then
    pass "migrate-todo: a failing glab issue create exits non-zero and records nothing as migrated"
  else
    fail "migrate-todo glab create failure" "$(gl_detail "$R_TODO_F")"
  fi
fi
case_end

case_begin "migrate-history-gitlab-goes-to-glab" "bin/github-issues/migration/migrate-history.sh"
if routes_through migrate-history.sh hia_issue_create hia_issue_close; then
  pass "migrate-history.sh creates and closes through hia_issue_create / hia_issue_close, never gh issue"
else
  fail "migrate-history.sh routing" "hia_issue_create / hia_issue_close missing or a direct gh issue call remains"
fi
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "migrate-history on a gitlab origin: jq not on PATH (the migration state needs it)"
else
  R_HIST="$(gl_repo history-gitlab history.md '# History\n\n### FEATURE: port the parser (2026-01-02, a1a1a1a, #1)\n\nbody line\n')"
  gl_migrate migrate-history.sh "$R_HIST"
  if [ "$GL_RC" -eq 0 ] && gl_log glab | grep -q 'issue create' && gl_log glab | grep -q 'issue close' && [ -z "$(gl_log forbidden)" ]; then
    pass "migrate-history on a gitlab origin creates and closes the issue with glab only"
  else
    fail "migrate-history on a gitlab origin" "$(gl_detail "$R_HIST")"
  fi
  if gl_create_ok "$R_HIST" "port the parser" "### FEATURE: port the parser (2026-01-02, a1a1a1a, #1)" "status:migrated type:task"; then
    pass "migrate-history on a gitlab origin: glab issue create gets origin's project, the title, the body and both labels"
  else
    fail "migrate-history glab issue create argv" "$(gl_detail "$R_HIST")"
  fi
  if [ "$(gl_call close | flag_vals -R --repo)" = "grp/history-gitlab" ] && gl_call close | sed '1,2d' | grep -qx '42'; then
    pass "migrate-history on a gitlab origin: glab issue close closes issue 42 in origin's project"
  else
    fail "migrate-history glab issue close argv" "$(gl_detail "$R_HIST")"
  fi
  if [ "$(gl_state "$R_HIST" '.history.migrated')" = '[{"entry_id":"h-0001","issue_number":42,"title":"port the parser"}]' ]; then
    pass "migrate-history on a gitlab origin: the state records h-0001 as GitLab issue 42"
  else
    fail "migrate-history state" "$(gl_detail "$R_HIST")"
  fi
fi
case_end

case_begin "migrate-history-gitlab-api-fails" "bin/github-issues/migration/migrate-history.sh"
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "migrate-history glab failures: jq not on PATH"
else
  for sub in create close; do
    R_HF="$(gl_repo "history-gitlab-$sub-fails" history.md '# History\n\n### FEATURE: port the parser (2026-01-02, a1a1a1a, #1)\n\nbody line\n')"
    gl_migrate migrate-history.sh "$R_HF" "$sub"
    if [ "$GL_RC" -ne 0 ] && gl_log glab | grep -q "issue $sub" && [ -z "$(gl_log forbidden)" ] && [ "$(gl_state "$R_HF" '.history.migrated | length')" != 1 ]; then
      pass "migrate-history: a failing glab issue $sub exits non-zero and records nothing as migrated"
    else
      fail "migrate-history glab $sub failure" "$(gl_detail "$R_HF")"
    fi
  done
fi
case_end

# A close that fails after the create leaves the issue number in pending_close; the re-run closes that
# issue instead of creating a duplicate.
case_begin "migrate-history-close-retry-reuses-issue" "bin/github-issues/migration/migrate-history.sh"
if [[ "$HAVE_JQ" -eq 0 ]]; then
  skip "migrate-history close retry: jq not on PATH"
else
  R_RETRY="$(gl_repo history-gitlab-close-retry history.md '# History\n\n### FEATURE: port the parser (2026-01-02, a1a1a1a, #1)\n\nbody line\n')"
  gl_migrate migrate-history.sh "$R_RETRY" close
  if [[ "$GL_RC" -ne 0 && "$(gl_state "$R_RETRY" '.history.pending_close')" == '{"h-0001":42}' && "$(gl_state "$R_RETRY" '[.history.migrated[]? | select(.entry_id == "h-0001")] | length')" == 0 ]]; then
    pass "migrate-history: a failed close records issue 42 as pending_close and h-0001 not as migrated"
  else
    fail "migrate-history close failure pending_close" "$(gl_detail "$R_RETRY") pending=[$(gl_state "$R_RETRY" '.history.pending_close')]"
  fi
  gl_migrate migrate-history.sh "$R_RETRY"
  if [[ "$GL_RC" -eq 0 ]] && ! gl_log glab | grep -q 'issue create' && gl_call close | sed '1,2d' | grep -qx '42' &&
    [[ "$(gl_state "$R_RETRY" '.history.migrated')" == '[{"entry_id":"h-0001","issue_number":42,"title":"port the parser"}]' && "$(gl_state "$R_RETRY" '.history.pending_close["h-0001"]')" == null ]]; then
    pass "migrate-history: the re-run closes pending issue 42 without a second create, records it migrated and clears pending_close"
  else
    fail "migrate-history close retry" "$(gl_detail "$R_RETRY") pending=[$(gl_state "$R_RETRY" '.history.pending_close')]"
  fi
fi
case_end

echo ""
echo "fix-gh-native-path: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
