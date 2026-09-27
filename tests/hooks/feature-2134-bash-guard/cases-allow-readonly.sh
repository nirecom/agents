# tests/hooks/feature-2134-bash-guard/cases-allow-readonly.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard/readonly-class.js, hooks/bash-guard/reasons.js, hooks/bash-guard/allow.js
# Tags: hook, bash-guard, classifier, readonly-allow, interlock, newline-guard, scope:issue-specific, pwsh-not-required, TL2
# R1-R8: the N3/N4/N5 read-only allow classes at judge level (#2403). Sourced by the dispatcher.

# WHY (#2403): settings.json globs (`git diff *`, `find *`) cannot bound argv; bash-guard reads
# the IR, so every positive gets a near-miss twin that must NOT allow (write, side effect,
# exec-capable option, foreign host, path cmd0, credential read, newline smuggling).
# bg_write_state (cases-interlock.sh) must already be sourced for R8.

# ra_rows <label> [sid] -- reads `name ~ command ~ verdict|code` rows from stdin.
ra_rows() {
    local label="$1" sid="${2:-}" name cmd want got
    while IFS='~' read -r name cmd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))
        got="$(verdict_code_of "$cmd" "$sid")"
        assert_eq "$label/$name: [$cmd]" "$want" "$got"
    done
}

case_begin "readonly-positive" "hooks/bash-guard/readonly-class.js"
# R1: every class answers with its own reason code, so a row cannot pass by landing in a
# sibling class (a gh read reported as GENERIC would hide a missing delegate).
ra_rows R1 <<'TABLE'
n3-ls            ~ ls -la                                ~ allow|BG-ALLOW-READONLY-GENERIC
n3-cat           ~ cat README.md                         ~ allow|BG-ALLOW-READONLY-GENERIC
n3-head          ~ head -n 5 f                           ~ allow|BG-ALLOW-READONLY-GENERIC
n3-wc            ~ wc -l f                               ~ allow|BG-ALLOW-READONLY-GENERIC
n3-find          ~ find . -name '*.js'                   ~ allow|BG-ALLOW-READONLY-GENERIC
n3-grep          ~ grep -rn x .                          ~ allow|BG-ALLOW-READONLY-GENERIC
n3-rg            ~ rg foo                                ~ allow|BG-ALLOW-READONLY-GENERIC
n3-tree          ~ tree -L 2                             ~ allow|BG-ALLOW-READONLY-GENERIC
n3-command-v     ~ command -v node                       ~ allow|BG-ALLOW-READONLY-GENERIC
n5-status        ~ git status                            ~ allow|BG-ALLOW-READONLY-GIT
n5-C-log         ~ git -C /tmp/x log --oneline -5        ~ allow|BG-ALLOW-READONLY-GIT
n5-no-textconv   ~ git diff --no-textconv                ~ allow|BG-ALLOW-READONLY-GIT
n5-no-ext-diff   ~ git diff --no-ext-diff                ~ allow|BG-ALLOW-READONLY-GIT
n5-format        ~ git log --format='%h %s'              ~ allow|BG-ALLOW-READONLY-GIT
n5-branch-a      ~ git branch -a                         ~ allow|BG-ALLOW-READONLY-GIT
n5-branch-cont   ~ git branch --contains HEAD            ~ allow|BG-ALLOW-READONLY-GIT
n5-tag-l         ~ git tag -l 'v*'                       ~ allow|BG-ALLOW-READONLY-GIT
n5-remote-v      ~ git remote -v                         ~ allow|BG-ALLOW-READONLY-GIT
n5-remote-show   ~ git remote show                       ~ allow|BG-ALLOW-READONLY-GIT
n5-remote-show-n ~ git remote show -n origin             ~ allow|BG-ALLOW-READONLY-GIT
n5-stash-list    ~ git stash list                        ~ allow|BG-ALLOW-READONLY-GIT
n5-worktree-list ~ git worktree list                     ~ allow|BG-ALLOW-READONLY-GIT
n4-pr-view       ~ gh pr view 12                         ~ allow|BG-ALLOW-READONLY-GH
n4-issue-R-post  ~ gh issue list -R o/r                  ~ allow|BG-ALLOW-READONLY-GH
n4-R-prefix      ~ gh -R o/r pr view 1                   ~ allow|BG-ALLOW-READONLY-GH
n4-api-get       ~ gh api repos/o/r/issues               ~ allow|BG-ALLOW-READONLY-GH
TABLE
# `HEAD~1` carries the table separator, so this positive sits outside the table.
ROWS=$((ROWS + 1))
assert_eq "R1/n5-no-pager: [git --no-pager diff HEAD~1]" \
    "allow|BG-ALLOW-READONLY-GIT" "$(verdict_code_of 'git --no-pager diff HEAD~1')"
case_end

case_begin "readonly-positive-full" "hooks/bash-guard/readonly-class.js"
# R1b: EVERY shipped N3 entry and EVERY PURE_READ subcommand allows end to end, so a data-file
# or subcommand-set omission cannot hide behind R1's representatives. Pin copies of the SSOT
# lists (install/readonly-command-classes.json; RS_PURE in fix-enforce-worktree-rtk-fail-open.sh).
RA_GENERIC=(ag cat command df du file find grep head ls pwd rg stat tail tree type uname wc which)
RA_PURE=(annotate blame cat-file check-attr check-ignore check-ref-format cherry count-objects describe
    diff diff-files diff-index diff-tree for-each-ref grep log ls-files ls-tree merge-base name-rev
    range-diff rev-list rev-parse shortlog show show-branch show-ref status var verify-pack version whatchanged)
ra_generic_cmd() {
    case "$1" in
        command) echo "command -v node" ;; find) echo "find . -name x" ;; pwd) echo "pwd" ;;
        uname) echo "uname -a" ;; df) echo "df -h" ;; which|type) echo "$1 node" ;; *) echo "$1 f" ;;
    esac
}
ra_rows R1b < <(
    for n in "${RA_GENERIC[@]}"; do printf 'gen-%s ~ %s ~ allow|BG-ALLOW-READONLY-GENERIC\n' "$n" "$(ra_generic_cmd "$n")"; done
    for s in "${RA_PURE[@]}"; do printf 'git-%s ~ git %s ~ allow|BG-ALLOW-READONLY-GIT\n' "$s" "$s"; done
)
case_end

case_begin "readonly-git-negative" "hooks/lib/bash-write-patterns/git-read-ir.js"
# R2: git writes, side-effecting reads, disallowed globals, and the holes the existing
# read/write classifier leaves open (`branch --delete -r`, `remote -v add`, `config edit`).
ra_rows R2 <<'TABLE'
add              ~ git add .                             ~ passThrough|BG-NO-HIT
fetch            ~ git fetch                             ~ passThrough|BG-NO-HIT
difftool         ~ git difftool                          ~ passThrough|BG-NO-HIT
archive          ~ git archive HEAD                      ~ passThrough|BG-NO-HIT
help-web         ~ git help -w log                       ~ passThrough|BG-NO-HIT
config-inject    ~ git -c core.pager=x log               ~ passThrough|BG-NO-HIT
exec-path        ~ git --exec-path=/x status             ~ passThrough|BG-NO-HIT
paginate         ~ git -p log                            ~ passThrough|BG-NO-HIT
C-commit         ~ git -C x commit -m y                  ~ passThrough|BG-NO-HIT
branch-del-r     ~ git branch --delete -r x              ~ passThrough|BG-NO-HIT
tag-sort-del     ~ git tag --sort=x --delete v1          ~ passThrough|BG-NO-HIT
remote-v-add     ~ git remote -v add a b                 ~ passThrough|BG-NO-HIT
config-edit      ~ git config edit                       ~ passThrough|BG-NO-HIT
config-get       ~ git config user.email                 ~ passThrough|BG-NO-HIT
branch-create    ~ git branch newb                       ~ passThrough|BG-NO-HIT
stash-drop       ~ git stash drop                        ~ passThrough|BG-NO-HIT
worktree-remove  ~ git worktree remove x                 ~ passThrough|BG-NO-HIT
diff-output      ~ git diff --output=f                   ~ passThrough|BG-NO-HIT
diff-outp-prefix ~ git diff --outp=f                     ~ passThrough|BG-NO-HIT
TABLE
case_end

case_begin "readonly-git-exec-capable" "hooks/lib/bash-write-patterns/git-read-ir.js"
# R3: options that launch an external program from a read (codex C1). Prefix forms included,
# because git accepts any unique abbreviation of a long option.
ra_rows R3 <<'TABLE'
diff-textconv    ~ git diff --textconv                   ~ passThrough|BG-NO-HIT
show-textconv    ~ git show --textconv HEAD              ~ passThrough|BG-NO-HIT
diff-textc       ~ git diff --textc                      ~ passThrough|BG-NO-HIT
catfile-textconv ~ git cat-file --textconv HEAD:f        ~ passThrough|BG-NO-HIT
catfile-filters  ~ git cat-file --filters HEAD:f         ~ passThrough|BG-NO-HIT
blame-textconv   ~ git blame --textconv f                ~ passThrough|BG-NO-HIT
log-ext-diff     ~ git log --ext-diff                    ~ passThrough|BG-NO-HIT
grep-O           ~ git grep -O x                         ~ passThrough|BG-NO-HIT
grep-open-pager  ~ git grep --open-files-in-pager x      ~ passThrough|BG-NO-HIT
show-signature   ~ git log --show-signature              ~ passThrough|BG-NO-HIT
format-G         ~ git log --format=%G?                  ~ passThrough|BG-NO-HIT
pretty-GS        ~ git show --pretty=format:%GS          ~ passThrough|BG-NO-HIT
fer-signature    ~ git for-each-ref --format='%(signature)' ~ passThrough|BG-NO-HIT
tag-verify       ~ git tag -v v1                         ~ passThrough|BG-NO-HIT
verify-commit    ~ git verify-commit HEAD                ~ passThrough|BG-NO-HIT
verify-tag       ~ git verify-tag v1                     ~ passThrough|BG-NO-HIT
remote-show-name ~ git remote show origin                ~ passThrough|BG-NO-HIT
ls-remote-upload ~ git ls-remote --upload-pack=x origin  ~ passThrough|BG-NO-HIT
TABLE
case_end

case_begin "readonly-gh-negative" "hooks/lib/bash-write-patterns/gh-read.js"
# R4: gh writes, non-allowlisted subcommands, --web, and gh api with a write/payload/override.
# R5: --hostname before AND after the subcommand, and host-qualified -R (codex C2) -- a read
# must never send the gh token to a host the user did not choose.
ra_rows R4 <<'TABLE'
pr-create        ~ gh pr create                          ~ passThrough|BG-NO-HIT
issue-close      ~ gh issue close 1                      ~ passThrough|BG-NO-HIT
pr-merge         ~ gh pr merge 1                         ~ passThrough|BG-NO-HIT
auth-status      ~ gh auth status                        ~ passThrough|BG-NO-HIT
pr-view-web      ~ gh pr view 1 --web                    ~ passThrough|BG-NO-HIT
repo-view-w      ~ gh repo view -w                       ~ passThrough|BG-NO-HIT
api-post         ~ gh api -X POST x                      ~ passThrough|BG-NO-HIT
api-field        ~ gh api x -f a=b                       ~ passThrough|BG-NO-HIT
api-input        ~ gh api x --input f                    ~ passThrough|BG-NO-HIT
api-override     ~ gh api -H 'X-HTTP-Method-Override: DELETE' x ~ passThrough|BG-NO-HIT
api-ambiguous    ~ gh api --unknown x                    ~ passThrough|BG-NO-HIT
api-XPOST-attach ~ gh api -XPOST x                       ~ passThrough|BG-NO-HIT
api-X-eq-POST    ~ gh api -X=POST x                      ~ passThrough|BG-NO-HIT
api-method-eq    ~ gh api --method=POST x                ~ passThrough|BG-NO-HIT
api-method-space ~ gh api --method POST x                ~ passThrough|BG-NO-HIT
api-patch        ~ gh api -X PATCH x                     ~ passThrough|BG-NO-HIT
api-delete       ~ gh api -X DELETE x                    ~ passThrough|BG-NO-HIT
api-put          ~ gh api -X PUT x                       ~ passThrough|BG-NO-HIT
api-get-f        ~ gh api -X GET x -f a=b                ~ passThrough|BG-NO-HIT
api-get-F        ~ gh api -X GET x -F a=b                ~ passThrough|BG-NO-HIT
api-get-field    ~ gh api -X GET x --field a=b           ~ passThrough|BG-NO-HIT
api-get-rawfield ~ gh api -X GET x --raw-field a=b       ~ passThrough|BG-NO-HIT
api-get-input    ~ gh api -X GET x --input f             ~ passThrough|BG-NO-HIT
TABLE
ra_rows R5 <<'TABLE'
host-pre-api     ~ gh --hostname h api x                 ~ passThrough|BG-NO-HIT
host-eq-pre-api  ~ gh --hostname=h api x                 ~ passThrough|BG-NO-HIT
host-mid-api     ~ gh api --hostname h x                 ~ passThrough|BG-NO-HIT
host-eq-post-api ~ gh api x --hostname=h                 ~ passThrough|BG-NO-HIT
host-pre-pr      ~ gh --hostname h pr view 1             ~ passThrough|BG-NO-HIT
host-post-pr     ~ gh pr view 1 --hostname h             ~ passThrough|BG-NO-HIT
R-host-pre       ~ gh -R h.example/o/r pr view 1         ~ passThrough|BG-NO-HIT
repo-host-post   ~ gh pr view 1 --repo=h.example/o/r     ~ passThrough|BG-NO-HIT
R-before-api     ~ gh -R o/r api x                       ~ passThrough|BG-NO-HIT
unknown-global   ~ gh --unknown pr view 1                ~ passThrough|BG-NO-HIT
TABLE
case_end

case_begin "readonly-generic-negative" "hooks/lib/readonly-syntax-adapters.js"
# R6: N3 near-misses -- find actions that write or exec, per-command deny flags (prefix and
# short-cluster forms), commands with no class, path/.exe/wrapper-spelled cmd0, and reads of
# credential or dotenv files that the credential guards own.
ra_rows R6 <<'TABLE'
find-delete      ~ find . -delete                        ~ passThrough|BG-NO-HIT
find-exec-plus   ~ find . -exec rm {} +                  ~ passThrough|BG-NO-HIT
find-fprint0     ~ find . -fprint0 out                   ~ passThrough|BG-NO-HIT
tree-o           ~ tree -o out                           ~ passThrough|BG-NO-HIT
rg-pre           ~ rg --pre x foo                        ~ passThrough|BG-NO-HIT
file-comp-prefix ~ file --comp x                         ~ passThrough|BG-NO-HIT
file-short-clust ~ file -zC x                            ~ passThrough|BG-NO-HIT
less             ~ less f                                ~ passThrough|BG-NO-HIT
command-wrapper  ~ command ls                            ~ passThrough|BG-NO-HIT
abs-path-cmd0    ~ /usr/bin/ls                           ~ passThrough|BG-NO-HIT
exe-cmd0         ~ ls.exe                                ~ passThrough|BG-NO-HIT
no-class-sort    ~ sort -o f g                           ~ passThrough|BG-NO-HIT
dotenv-cat       ~ cat .env                              ~ passThrough|BG-NO-HIT
dotenv-grep      ~ grep x .env                           ~ passThrough|BG-NO-HIT
dotenv-nested    ~ cat config/.env                       ~ passThrough|BG-NO-HIT
dotenv-nest-prod ~ grep x config/.env.production         ~ passThrough|BG-NO-HIT
dotenv-deep-tail ~ tail sub/dir/.env.local               ~ passThrough|BG-NO-HIT
cred-home-var    ~ cat $HOME/.ssh/id_rsa                 ~ passThrough|BG-NO-HIT
TABLE
# `~/.ssh` carries the table separator, so the credential row sits outside the table.
ROWS=$((ROWS + 1))
assert_eq "R6/credential-cat: [cat ~/.ssh/id_rsa]" \
    "passThrough|BG-NO-HIT" "$(verdict_code_of 'cat ~/.ssh/id_rsa')"
case_end

case_begin "readonly-structural" "hooks/bash-guard/judge.js"
# R7: structure outranks class. deny forms stay deny (deny > allow); a newline or CR turns one
# visible command into two, so it skips the WHOLE allow path -- self-script included (the SELF_*
# newline hole this issue closes); forms settings.json denies must never become allow.
ra_rows R7 <<'TABLE'
env-prefix       ~ A=1 ls                                ~ deny|BG-ENV-PREFIX
env-ext-diff     ~ GIT_EXTERNAL_DIFF=x git diff          ~ deny|BG-ENV-PREFIX
pipe             ~ ls | head                             ~ deny|BG-PIPE
redirect         ~ ls > f                                ~ deny|BG-REDIRECT-OUT
newline-git      ~ git status\nrm -rf x                  ~ passThrough|BG-NO-HIT
newline-self     ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list\nrm x ~ passThrough|BG-NO-HIT
settings-find    ~ find . -exec rm -rf {} \;             ~ passThrough|BG-NO-HIT
settings-push    ~ git push --force                      ~ passThrough|BG-NO-HIT
settings-noverif ~ git commit --no-verify                ~ passThrough|BG-NO-HIT
settings-reset   ~ git reset --hard                      ~ passThrough|BG-NO-HIT
settings-clean   ~ git clean -fd                         ~ passThrough|BG-NO-HIT
TABLE
ROWS=$((ROWS + 1))
assert_eq "R7/cr-git: a CR inside the command skips the allow path" \
    "passThrough|BG-NO-HIT" "$(verdict_code_of $'git status\rrm -rf x')"
# Vacuity guard for newline-self: the same self-script without the newline IS allowed.
ROWS=$((ROWS + 1))
assert_eq "R7/self-script-baseline: the one-line self-script still allows" \
    "allow|BG-ALLOW-SELF-SCRIPT" "$(verdict_code_of 'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list')"
case_end

case_begin "readonly-interlock" "hooks/bash-guard/judge.js"
# R8: while the early write gate is armed, bash-guard stays silent EXCEPT for a plain
# read-only command (the gate blocks Edit/Write only; clarify-intent research is read-heavy).
# Anything else -- compound, write, self-script, unparseable, newline -- stays INTERLOCK_QUIET.
BG_SID_RO_GATE="sid-bg-ro-gate-armed"
bg_write_state "$BG_SID_RO_GATE" "pending"
ROWS=$((ROWS + 1))
assert_eq "R8/vacuity: the fixture session has the early write gate active" \
    "true	workflow_init	-" "$(probe gate '' "$BG_SID_RO_GATE")"
ra_rows R8 "$BG_SID_RO_GATE" <<'TABLE'
git-status       ~ git status                            ~ allow|BG-ALLOW-READONLY-GIT
ls               ~ ls -la                                ~ allow|BG-ALLOW-READONLY-GENERIC
gh-pr-view       ~ gh pr view 1                          ~ allow|BG-ALLOW-READONLY-GH
compound        ~ git status && ls                      ~ passThrough|BG-INTERLOCK-QUIET
write            ~ git add .                             ~ passThrough|BG-INTERLOCK-QUIET
self-script      ~ node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --list ~ passThrough|BG-INTERLOCK-QUIET
parse-failure    ~ ls "unterminated                      ~ passThrough|BG-INTERLOCK-QUIET
newline          ~ git status\nls                        ~ passThrough|BG-INTERLOCK-QUIET
TABLE
case_end

# Row count (dispatcher ROWS_EXPECTED): R1 26+1, R1b 19+32, R2 19, R3 18, R4 23, R5 10,
# R6 18+1, R7 11+2, R8 1+8 = 189.
