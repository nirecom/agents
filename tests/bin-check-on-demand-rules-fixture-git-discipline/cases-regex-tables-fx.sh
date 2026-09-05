# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, table-driven, TL2, scope:common
# The fixtures.sh BODY scanners, row by row (skills/_shared/test-design/parser-regex-tests.md).
# D8/D10/D12 read a body that does not exist yet, so they carry ONE spelling each at most
# and a regex that is too loose or too tight is invisible there. Every row below is a
# spelling the implementer may plausibly write; the no-match half is the false-positive
# boundary, the match half the false-negative one.

echo ""
echo "=== D8t: SWALLOW_RE — the two spellings that discard a failure, and the ones that act ==="
re_table D8t "$SWALLOW_RE" <<'TABLE'
or-true             | cp -R "$T/.git" "$d/.git" ^^ true  | match
or-colon            | git -C "$d" add "$@" ^^ :          | match
or-true-nospace     | cp -R "$T" "$d" ^^true; return 0   | match
or-return           | cp -R "$T/.git" "$d/.git" ^^ return 1 | no-match
or-fail             | git -C "$d" add "$@" ^^ fail "no"  | no-match
if-not-guard        | if ! cp -R "$T/.git" "$d/.git"; then  | no-match
truthy-word         | cmd ^^ truthy_helper "$d"          | no-match
TABLE

echo ""
echo "=== D8u: CP_CALL_RE — cp in command position, not cp as a name fragment ==="
re_table D8u "$CP_CALL_RE" <<'TABLE'
line-start-cp       | cp -R "$T/.git" "$d/.git"          | match
indented-cp         | ~~~~cp -R "$T/.git" "$d/.git"      | match
guarded-cp          | if ! cp -a "$T/.git" "$d/.git"; then  | match
after-separator     | cd "$d" && cp -R "$T/.git" .git    | match
scp-not-cp          | scp -r "$T" host:/tmp              | no-match
cp-underscore       | cp_helper "$T" "$d"                | no-match
cpio-tool           | cpio -o -H newc                    | no-match
dot-cp-suffix       | mv a.cp b.cp                       | no-match
TABLE

echo ""
echo "=== D8v: CP_GUARDED_RE — the handlers that act, separated from a bare cp ==="
# D8a subtracts SWALLOW_RE from this set, so `cp … || true` must MATCH here (it is a
# handler) and be removed there (it is not one that acts). Both halves are needed.
re_table D8v "$CP_GUARDED_RE" <<'TABLE'
if-not-form         | if ! cp -R "$T/.git" "$d/.git"; then  | match
or-return-form      | ~~~~cp -R "$T/.git" "$d/.git" ^^ return 1 | match
or-true-form        | ~~~~cp -R "$T/.git" "$d/.git" ^^ true | match
bare-cp             | ~~~~cp -R "$T/.git" "$d/.git"      | no-match
if-without-bang     | if cp -R "$T/.git" "$d/.git"; then | no-match
line-start-bare     | cp -R "$T/.git" "$d/.git"          | no-match
TABLE

echo ""
echo "=== D8w: GIT_ADD_RE — git add with or without flags between the two words ==="
re_table D8w "$GIT_ADD_RE" <<'TABLE'
dash-C-add          | git -C "$d" add "$@"               | match
plain-add           | git add -A                         | match
exe-add             | git.exe -C "$d" add -A             | match
add-at-eol          | cd "$d" && git add                 | match
diff-not-add        | git -C "$d" diff --cached          | no-match
addendum-word       | git addendum --dry-run             | no-match
quoted-prose-add    | git commit -m "add a rule"         | no-match
mygit-add           | mygit add "$@"                     | no-match
TABLE

echo ""
echo "=== D8x: GIT_ADD_GUARDED_RE — CPR-ORTH: D8v's shape applied to git add ==="
re_table D8x "$GIT_ADD_GUARDED_RE" <<'TABLE'
if-not-add          | if ! git -C "$d" add "$@"; then    | match
or-return-add       | ~~~~git -C "$d" add "$@" ^^ return 1 | match
or-true-add         | ~~~~git -C "$d" add "$@" ^^ true   | match
bare-add            | ~~~~git -C "$d" add "$@" >/dev/null 2>&1 | no-match
if-without-bang-add | if git -C "$d" add "$@"; then      | no-match
line-start-bare-add | git add -A                         | no-match
TABLE

echo ""
echo "=== D8y: STAGED_ENUM_RE — run_checker really enumerates the staged files ==="
re_table D8y "$STAGED_ENUM_RE" <<'TABLE'
dash-C-diff         | git -C "$d" diff --cached --name-only | match
plain-diff          | git diff --cached                  | match
exe-diff            | git.exe -C "$d" diff --cached      | match
diff-head           | git -C "$d" diff HEAD              | no-match
prose-mention       | echo "diff --cached lists them"    | no-match
hyphenated-git      | git-diff --cached                  | no-match
mygit-diff          | mygit diff --cached                | no-match
TABLE

echo ""
echo "=== D10t: EARLY_GIT_TEST_RE — the -d …/.git test the idempotency claim rests on ==="
re_table D10t "$EARLY_GIT_TEST_RE" <<'TABLE'
bracket-test        | [ -d "$d/.git" ] && return 0       | match
dbl-bracket-test    | if [[ -d "$1/.git" ]]; then        | match
template-test       | [ -d "$FX_GIT_TEMPLATE/.git" ] && return 0 | match
file-not-dir        | [ -f "$d/.git" ] && return 0       | no-match
dir-without-git     | [ -d "$d" ] && return 0            | no-match
mkdir-not-test      | mkdir -p "$d/.git"                 | no-match
no-space-after-flag | [ -d"$d/.git" ]                    | no-match
TABLE

echo ""
echo "=== D12t: HOOKS_OFF_RE — core.hooksPath PERSISTED, not overridden for one command ==="
# The ephemeral `git -c core.hooksPath=…` form is the false green this table exists for:
# it suppresses hooks for exactly one command and writes nothing into .git/config, so a
# template built with it hands every clone the host's hooksPath while D12a stays green.
# E3/E4 demonstrate the same split against real git; these rows pin the reader.
re_table D12t "$HOOKS_OFF_RE" <<'TABLE'
config-space-form   | git -C "$1" config core.hooksPath /dev/null | match
config-local-form   | git config --local core.hooksPath /dev/null | match
config-replace-all  | git config --local --replace-all core.hooksPath /dev/null | match
c-prefix-then-config| git -c color.ui=false config core.hooksPath /dev/null | match
dash-c-equals-form  | git -c core.hooksPath=/dev/null status | no-match
dash-c-then-config  | git -c core.hooksPath=/dev/null config user.name Test | no-match
dash-c-equals-commit| git -c core.hooksPath=/dev/null -C "$d" commit -q -m x | no-match
wrong-value         | git config core.hooksPath .githooks | no-match
lowercase-key       | git config core.hookspath /dev/null | no-match
no-namespace        | git config hooksPath /dev/null     | no-match
key-only-read       | git config --get core.hooksPath    | no-match
config-word-fragment| git reconfig core.hooksPath /dev/null | no-match
TABLE

echo ""
echo "=== D12u: CLONE_WHOLE_GIT_RE — a whole .git carried to a whole .git, nothing less ==="
# A subset copy is the silent failure this exists for: `.git/config` alone leaves the
# template's core.hooksPath behind while every other check still reads green.
re_table D12u "$CLONE_WHOLE_GIT_RE" <<'TABLE'
plain-clone         | cp -R "$FX_GIT_TEMPLATE/.git" "$d/.git" | match
guarded-clone       | cp -R "$T/.git" "$1/.git" ^^ return 1 | match
if-not-clone        | if ! cp -a "$T/.git" "$d/.git"; then | match
subset-copy         | cp -R "$T/.git/config" "$d/.git/config" | no-match
dest-not-git        | cp -R "$T/.git" "$d"               | no-match
src-not-git         | cp -R "$T/objects" "$d/.git"       | no-match
no-cp-at-all        | mkdir -p "$d/.git"                 | no-match
TABLE

echo ""
echo "=== D12v: REINIT_RE — the clone path must not rebuild what it just copied ==="
re_table D12v "$REINIT_RE" <<'TABLE'
git-init            | git init -q --template="$t" "$d"   | match
git-config          | git -C "$1" config core.hooksPath /dev/null | match
exe-init            | git.exe init -q "$d"               | match
git-add             | git -C "$d" add "$@"               | no-match
initialize-word     | git initialize --now               | no-match
helper-name         | fx_git_init "$d"                   | no-match
diff-cached         | git -C "$d" diff --cached          | no-match
TABLE

echo ""
echo "=== D9t: scan_file_scope_git — the nesting states D9a/D9b/D9c depend on ==="
# D9b plants one shape and D9c three; the parser has more states than that. `@` is a
# newline here, so each row is a whole file and the want column is the hit count.
D9T_SRC="$WORK/d9-scope.sh"
scope_hits() {
    local s
    s="$(tbl_input "$1")"
    printf '%s\n' "${s//@/$'\n'}" > "$D9T_SRC"
    scan_file_scope_git "$D9T_SRC" | grep -c . || true
}
while IFS='|' read -r _name _in _want; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"
    _want="${_want//[[:space:]]/}"
    assert_eq "D9t/$_name" "$_want" "$(scope_hits "$_in")"
done <<'TABLE'
top-level-call       | git~init~-q~"$T"                            | 1
after-fn-close       | mk()~{@git~init~-q@}@git~add~-A~"$d"        | 1
oneliner-then-top    | fx()~{~fx_ensure_git~"$1";~}@git~init~-q    | 1
indented-top-level   | ~~~~git~init~-q~"$T"                        | 1
inside-paren-fn      | mk()~{@git~init~-q~"$1"@}                   | 0
inside-function-kw   | function~gc~{@git~commit~-q~-m~x@}          | 0
comment-line         | #~git~init~-q~"$T"                          | 0
prose-no-git         | echo~"nothing~to~see~here"                  | 0
TABLE
