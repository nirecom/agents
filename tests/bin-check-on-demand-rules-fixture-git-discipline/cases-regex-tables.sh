# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, table-driven, TL2, scope:common
# Table-driven parser fixation (skills/_shared/test-design/parser-regex-tests.md).
# D6/D6b/D7/D11t pin the text scanners D1/D2/D9/D11 are built out of, over inputs
# D3/D4/D3b can never reach: a planted tree carries one spelling each, so widening a
# scanner too far, or leaving it too narrow, is invisible there.

echo ""
echo "=== D6: GIT_CALL_RE — every spelling the D1/D2 scans must and must not see ==="
re_table D6 "$GIT_CALL_RE" <<'TABLE'
bare-call           | git init -q                       | match
dash-C-call         | git -C "$d" commit -m baseline    | match
after-separator     | cd "$d" && git add -A             | match
indented-call       | ~~~~git status --porcelain        | match
line-continuation   | git \                             | match
redirect-first      | git 2>/dev/null status            | match
quoted-command      | "git" -C "$d" add -A              | match
exe-bare-call       | git.exe init -q                   | match
exe-after-separator | cd "$d" && git.exe add -A         | match
exe-quoted-command  | "git.exe" -C "$d" add -A          | match
fx-ensure-git       | fx_ensure_git "$d"                | no-match
git-commit-all      | git_commit_all "$d"               | no-match
dot-gitignore       | cp x .gitignore                   | no-match
hyphen-flag         | --git-dir=/tmp/x                  | no-match
hyphenated-subcmd   | git-foo --bar baz                 | no-match
embedded-word       | mygit status                      | no-match
gitk-viewer         | gitk --all                        | no-match
legit-prefix        | legit reason to skip the case     | no-match
digit-prefix        | digit count must stay at 4        | no-match
bare-word-at-eol    | route everything through git      | no-match
mention-then-hash   | git # named, never invoked        | no-match
exe-mention-hash    | git.exe # named, never invoked    | no-match
string-literal-dq   | echo "git status"                 | no-match
string-literal-sq   | printf 'git add -A'               | no-match
exe-literal-dq      | echo "git.exe status"             | no-match
TABLE

echo ""
echo "=== D6b: GIT_ALIAS_ASSIGN_RE — the indirect route, pinned at the assignment ==="
# A `$GIT add` call site is undecidable from text alone; the assignment that creates the
# alias is not, so that is what D1 detects and this table fixes. The must-not rows are
# what keeps the widening from flagging every path variable that merely ends in `git`.
re_table D6b "$GIT_ALIAS_ASSIGN_RE" <<'TABLE'
bare-alias          | GIT=git                           | match
quoted-alias        | GIT="git"                         | match
abs-path-alias      | GIT=/usr/bin/git                  | match
exe-path-alias      | GIT="/usr/bin/git.exe"            | match
lowercase-alias     | git_bin=git                       | match
alias-then-semi     | GIT=git; export GIT               | match
dir-not-binary      | d="$BASE/git"                     | no-match
relative-path-var   | REPO=$BASE/git                    | no-match
gitk-binary         | VIEWER=/usr/bin/gitk              | no-match
env-prefix-call     | GIT_DIR=/tmp/x git status         | no-match
equality-test       | if [ "$x" = git ]                 | no-match
prose-mention       | route everything through git      | no-match
TABLE

echo ""
echo "=== D6r: GIT_ROUTE_RE — the union D1 actually runs, not either half alone ==="
# D6/D6b pin the two halves; the union is a third constant and D1 runs THAT one. Drop
# either alternation from it and the rows below split — direct-only or alias-only.
re_table D6r "$GIT_ROUTE_RE" <<'TABLE'
direct-half         | git -C "$d" add -A                | match
direct-exe-half     | git.exe init -q                   | match
alias-half          | GIT=/usr/bin/git.exe              | match
alias-bare-half     | GIT=git                           | match
routed-call         | fx_stage "$d" rules/cond.md       | no-match
dir-not-binary      | d="$BASE/git"                     | no-match
string-literal-dq   | echo "git status"                 | no-match
gitk-viewer         | gitk --all                        | no-match
TABLE

echo ""
echo "=== D7: fixtures.sh function-name extraction covers both definition syntaxes ==="
D7_SRC="$WORK/fx-syntax.sh"
extract_one() {
    printf '%s\n' "$1" > "$D7_SRC"
    extract_fx_names "$D7_SRC" | tr '\n' ','
}
while IFS='|' read -r _name _in _want; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"
    _want="${_want//[[:space:]]/}"
    assert_eq "D7/$_name" "$_want" "$(extract_one "$(tbl_input "$_in")")"
done <<'TABLE'
paren-form          | fx_stage() {                      | fx_stage,
paren-spaced        | fx_stage () {                     | fx_stage,
function-keyword    | function fx_ensure_git {          | fx_ensure_git,
function-and-paren  | function fx_ensure_git () {       | fx_ensure_git,
underscore-private  | _fx_git_template() {              | _fx_git_template,
function-prefixed   | functional_helper() {             | functional_helper,
indented-nested     | ~~nested() {                      |
commented-out       | # fx_stage() is documented here   |
call-not-definition | fx_stage "$d" rules/cond.md       |
TABLE

echo ""
echo "=== D11t: UNQUOTED_EXP_RE — the three quoting states D11 must keep apart ==="
match_unquoted() {
    if printf '%s\n' "$1" | strip_quoted | grep -qE -- "$UNQUOTED_EXP_RE"; then printf 'unquoted'; else printf 'quoted'; fi
}
while IFS='|' read -r _name _in _want; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"
    _want="${_want//[[:space:]]/}"
    assert_eq "D11t/$_name" "$_want" "$(match_unquoted "$(tbl_input "$_in")")"
done <<'TABLE'
bare-var             | git init -q $d                    | unquoted
bare-braced          | mkdir -p ${d}                     | unquoted
bare-inside-path     | cp -R $T/.git $d/.git             | unquoted
bare-positional-all  | git -C "$d" add $@                | unquoted
dq-var               | git init -q "$d"                  | quoted
dq-braced            | mkdir -p "${d}"                   | quoted
dq-both-paths        | cp -R "$T/.git" "$d/.git"         | quoted
dq-inside-sentence   | printf '%s' "repo at $d"          | quoted
sq-never-expands     | printf '%s' '$d'                  | quoted
no-expansion-at-all  | git init -q                       | quoted
command-substitution | d="$(mktemp -d)"                  | quoted
TABLE
