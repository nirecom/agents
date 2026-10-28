# tests/hooks/feature-2134-bash-guard/cases-git-deviant.sh
# Tests: hooks/bash-guard/git-deviant.js, hooks/bash-guard/git-deviant/forms.js, hooks/bash-guard/git-deviant/options.js, hooks/bash-guard/git-deviant/push.js, hooks/bash-guard/git-deviant/clean.js, hooks/bash-guard/git-deviant/worktree-remove.js, hooks/bash-guard/judge.js, hooks/bash-guard/message.js, hooks/bash-guard/reasons.js, hooks/bash-guard.js
# Tags: hook, bash-guard, git-deviant, git-push, force-push, worktree-remove, git-clean, classifier, guard, interlock, scope:issue-specific, pwsh-not-required, TL2
# G1-G16: the git-deviant detector (#2617). Sourced after cases-interlock.sh and cases-runtime-pretooluse.sh.

GD_H40="0123456789abcdef0123456789abcdef01234567"

# WHY (#2617): the substring glob `Bash(git push *-f*)` denied `feature/2572-feature-x`, worktree
# paths like `2765-find-...` and `--force-with-lease`. The detector reads parsed argv instead. Every
# deny row pins verdict, code AND formId; every look-alike row pins the exact non-deny answer.
# git-deviant is a SECURITY guard: unlike the literals it still denies under the interlock.

# gd_triple_of <command-text> [sessionId] -> "<verdict>|<code>|<literalId|notifyId|formId>";
# a <MISSING:...>/<THREW:...> line is returned verbatim (it never equals a want).
gd_triple_of() {
    local line
    line="$(probe judge "$1" "${2:-}")"
    case "$line" in
        "<"*) printf '%s' "$line" ;;
        *) printf '%s' "${line//$'\t'/|}" ;;
    esac
}

# gd_rows <label>: stdin table `name ~ command ~ sid ~ want`; `@H40@` in a command expands to a
# 40-char lowercase sha, `@U40@` to its uppercase form, `@H39@` / `@H41@` to one char short / long,
# `@X40@` to 40 chars whose last is the non-hex `g`; sid `-` = settled, `ARMED` = gate armed.
gd_rows() {
    local label="$1" name cmd sid want
    while IFS='~' read -r name cmd sid want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        sid="${sid//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        cmd="${cmd//@H40@/$GD_H40}"
        cmd="${cmd//@U40@/${GD_H40^^}}"
        cmd="${cmd//@H39@/${GD_H40:0:39}}"
        cmd="${cmd//@H41@/${GD_H40}8}"
        cmd="${cmd//@X40@/${GD_H40:0:39}g}"
        [[ "$sid" == "-" ]] && sid=""
        [[ "$sid" == "ARMED" ]] && sid="$BG_SID_ARMED"
        ROWS=$((ROWS + 1))

        assert_eq "$label/$name: verdict|code|id" "$want" "$(gd_triple_of "$cmd" "$sid")"
    done
}

# g8_message_rows: stdin table `name ~ has|not ~ command ~ fragment` against the deny message.
g8_message_rows() {
    local name cmd frag mode got
    while IFS='~' read -r name mode cmd frag; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        mode="${mode//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        frag="$(mkcmd "$frag")"
        ROWS=$((ROWS + 1))

        got="$(probe judge-message "$cmd")"
        # A `<MISSING:...>` sentinel is not a message: blank it so no fragment matches inside it.
        case "$got" in "<"*) got="" ;; esac
        if [[ "$mode" == "has" ]]; then
            assert_contains "G8/$name: the deny message carries [$frag]" "$frag" "$got"
        elif [[ -z "$got" ]]; then
            fail "G8/$name: no deny message to check (want one without [$frag])" "$cmd"
        else
            assert_not_contains "G8/$name: the deny message does not echo the command" "$frag" "$got"
        fi
    done
}

# G1: every deviant spelling the plan names, one deny per row with its form.
case_begin "git-deviant-deny-forms" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G1 <<'TABLE'
push-f-lead        ~ git push -f origin main               ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-f-trail       ~ git push origin main -f               ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-force-long    ~ git push --force origin main          ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-uf-cluster    ~ git push -uf origin main              ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-ud-cluster    ~ git push -ud origin x                 ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
push-plus-ref      ~ git push origin +main                 ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
push-plus-src-dst  ~ git push origin +HEAD:main            ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
push-colon-delete  ~ git push origin :old-branch           ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
push-colon-alone   ~ git push origin :                     ~ - ~ deny|BG-GIT-PUSH-MATCHING-REFSPEC|push-matching-refspec
push-delete-long   ~ git push --delete origin x            ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
push-d-short       ~ git push -d origin x                  ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
push-del-abbrev    ~ git push --del origin x               ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
push-mirror        ~ git push --mirror origin              ~ - ~ deny|BG-GIT-PUSH-MIRROR|push-mirror
push-mirr-abbrev   ~ git push --mirr origin                ~ - ~ deny|BG-GIT-PUSH-MIRROR|push-mirror
wt-remove-f        ~ git worktree remove -f ../wt          ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-remove-force    ~ git worktree remove --force ../wt     ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-remove-f-trail  ~ git worktree remove ../wt -f          ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
clean-f            ~ git clean -f                          ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-fd           ~ git clean -fd                         ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-df           ~ git clean -df                         ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-xdf          ~ git clean -xdf                        ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-force-long   ~ git clean --force                     ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-nf-dry-run   ~ git clean -nf                         ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
TABLE
case_end

# G2: with `--repo` the remote comes from the option, so EVERY positional is a refspec. A detector
# that always skips the first positional as "the remote" would miss `+main` / `:old` here.
case_begin "git-deviant-repo-remote" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G2 <<'TABLE'
repo-sep-plus      ~ git push --repo origin +main                    ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
repo-eq-plus       ~ git push --repo=origin +main                    ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
repo-sep-colon     ~ git push --repo origin :old                     ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
repo-eq-colon      ~ git push --repo=origin :old                     ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
rep-abbrev-plus    ~ git push --rep origin +main                     ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
repo-sep-plain     ~ git push --repo origin main                     ~ - ~ passThrough|BG-NO-HIT|-
repo-eq-hyphen-f   ~ git push --repo=origin feature/2572-feature-x   ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G3: `-f` inside a value, a path or after `--` is not the force flag -- the #2617 false-deny class.
# peer-* reproduce the reported real-world deny: a worktree path containing `-find`, in four launch forms.
case_begin "git-deviant-lookalike-non-deny" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G3 <<'TABLE'
push-hyphen-f-branch ~ git push -u origin feature/2572-feature-x   ~ - ~ passThrough|BG-NO-HIT|-
push-inner-plus      ~ git push origin a+b                         ~ - ~ passThrough|BG-NO-HIT|-
wt-path-hyphen-f     ~ git worktree remove ../wt-feature-x         ~ - ~ passThrough|BG-NO-HIT|-
wt-f-after-dashdash  ~ git worktree remove ../wt -- -f             ~ - ~ passThrough|BG-NO-HIT|-
clean-f-after-dashdash ~ git clean -n -- -f                        ~ - ~ passThrough|BG-NO-HIT|-
clean-dry-run        ~ git clean -n                                ~ - ~ passThrough|BG-NO-HIT|-
clean-e-value-f      ~ git clean -e -fixture -n                    ~ - ~ passThrough|BG-NO-HIT|-
clean-path-fd        ~ git clean -n -- dir-fd                      ~ - ~ passThrough|BG-NO-HIT|-
push-o-value-f       ~ git push -o ci.skip-f origin x              ~ - ~ passThrough|BG-NO-HIT|-
clean-e-exact-f      ~ git clean -e -f -n                          ~ - ~ passThrough|BG-NO-HIT|-
push-o-exact-f       ~ git push -o -f origin main                  ~ - ~ passThrough|BG-NO-HIT|-
peer-plain           ~ git worktree remove C:/git/worktrees/2765-find-pr-by-marker-sh/agents                        ~ - ~ passThrough|BG-NO-HIT|-
peer-dash-C          ~ git -C C:/git/agents worktree remove C:/git/worktrees/2765-find-pr-by-marker-sh/agents       ~ - ~ passThrough|BG-NO-HIT|-
peer-dash-c          ~ git -c a.b=c worktree remove C:/git/worktrees/2765-find-pr-by-marker-sh/agents              ~ - ~ passThrough|BG-NO-HIT|-
peer-no-pager        ~ git --no-pager worktree remove C:/git/worktrees/2765-find-pr-by-marker-sh/agents            ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G15: a LONG value-taking option consumes the next token too, so a `-f` right after
# `--push-option` / `--exclude` is that option's value, not the force flag. A scan that only
# knows the short value-taking options (`-o`, `-e`) would deny these -- the #2617 false-deny class.
case_begin "git-deviant-long-value-option" "hooks/bash-guard/git-deviant/options.js"
bg_batched_stdin gd_rows G15 <<'TABLE'
push-option-long-f ~ git push --push-option -f origin main ~ - ~ passThrough|BG-NO-HIT|-
clean-exclude-f    ~ git clean --exclude -f -n             ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G4: the lease. Only the explicit `=<ref>:<40 lowercase hex>` form proves the pusher looked at the
# remote tip; bare, ref-only, short-sha and uppercase spellings are implicit leases and deny.
case_begin "git-deviant-lease" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G4 <<'TABLE'
lease-explicit       ~ git push --force-with-lease=main:@H40@ origin main                     ~ - ~ passThrough|BG-NO-HIT|-
no-lease             ~ git push --no-force-with-lease origin x                                ~ - ~ passThrough|BG-NO-HIT|-
no-force-long        ~ git push --no-force origin main                                        ~ - ~ passThrough|BG-NO-HIT|-
if-includes-explicit ~ git push --force-if-includes --force-with-lease=main:@H40@ origin main ~ - ~ passThrough|BG-NO-HIT|-
lease-bare           ~ git push --force-with-lease origin main                                ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-ref-only       ~ git push --force-with-lease=main origin main                           ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-short-sha      ~ git push --force-with-lease=main:abc123 origin main                    ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-upper-hex      ~ git push --force-with-lease=main:@U40@ origin main                     ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-sha-39         ~ git push --force-with-lease=main:@H39@ origin main                     ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-sha-41         ~ git push --force-with-lease=main:@H41@ origin main                     ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-sha-40-nonhex  ~ git push --force-with-lease=main:@X40@ origin main                     ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-empty-ref      ~ git push --force-with-lease=:@H40@ origin main                         ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
lease-empty-value    ~ git push --force-with-lease= origin main                               ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
TABLE
case_end

# G12: a valid lease never masks another deviant argument in the same push. A detector that accepts
# the explicit lease and stops scanning would let `--force`, `+refspec` or `:refspec` ride along, so
# each prohibited argument sits both before and after the lease.
case_begin "git-deviant-lease-with-deviant" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G12 <<'TABLE'
lease-then-force   ~ git push --force-with-lease=main:@H40@ --force origin main ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
force-then-lease   ~ git push --force --force-with-lease=main:@H40@ origin main ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
lease-then-f       ~ git push --force-with-lease=main:@H40@ -f origin main      ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
f-then-lease       ~ git push -f --force-with-lease=main:@H40@ origin main      ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
lease-then-plus    ~ git push --force-with-lease=main:@H40@ origin +main        ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
plus-then-lease    ~ git push origin +main --force-with-lease=main:@H40@        ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
lease-then-delete  ~ git push --force-with-lease=main:@H40@ origin :old         ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
delete-then-lease  ~ git push origin :old --force-with-lease=main:@H40@         ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
TABLE
case_end

# G13: long options expand by unique prefix (`--force-with` and `--force-w` name only force-with-lease),
# so the abbreviated lease obeys the same explicit-only rule. The settings.json lease rows match the
# full spelling only; the hook is the one layer that reads the abbreviation.
case_begin "git-deviant-lease-abbrev" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G13 <<'TABLE'
abbrev-explicit       ~ git push --force-with=main:@H40@ origin main         ~ - ~ passThrough|BG-NO-HIT|-
abbrev-w-explicit     ~ git push --force-w=main:@H40@ origin main            ~ - ~ passThrough|BG-NO-HIT|-
abbrev-bare           ~ git push --force-with origin main                    ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
abbrev-ref-only       ~ git push --force-with=main origin main               ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
abbrev-short-sha      ~ git push --force-w=main:abc123 origin main           ~ - ~ deny|BG-GIT-PUSH-LEASE-IMPLICIT|push-lease-implicit
abbrev-explicit-force ~ git push --force-with=main:@H40@ --force origin main ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
TABLE
case_end

# G11: after `--` every token is a positional. A refspec there still forces or deletes, while an
# option-looking token there is only a branch name -- reading it as `-f` is the #2617 false deny.
case_begin "git-deviant-push-dashdash" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G11 <<'TABLE'
dd-plus-src-dst   ~ git push origin -- +HEAD:main      ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
dd-colon-delete   ~ git push origin -- :old            ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
dd-repo-plus      ~ git push --repo origin -- +main    ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
dd-short-f-branch ~ git push origin -- -f              ~ - ~ passThrough|BG-NO-HIT|-
dd-long-f-branch  ~ git push origin -- --force         ~ - ~ passThrough|BG-NO-HIT|-
dd-plain-branch   ~ git push origin -- feature/x       ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G5: launch forms and wrappers. git's own global options and the env/command/path/.exe wrappers
# must not hide the subcommand. `env FOO=1 git` raises no env-prefix literal (env is cmd0), so the
# git-deviant code is the expected answer in every row.
case_begin "git-deviant-launch-forms" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G5 <<'TABLE'
push-dash-C     ~ git -C /x push -f origin main             ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-dash-c     ~ git -c a.b=c push -f origin main          ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-no-pager   ~ git --no-pager push -f origin main        ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-env        ~ env FOO=1 git push -f origin main         ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-command    ~ command git push -f origin main           ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-abs-path   ~ /usr/bin/git push -f origin main          ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
push-exe        ~ git.exe push -f origin main               ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
wt-dash-C       ~ git -C /x worktree remove -f ../wt        ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-dash-c       ~ git -c a.b=c worktree remove -f ../wt     ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-no-pager     ~ git --no-pager worktree remove -f ../wt   ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-env          ~ env FOO=1 git worktree remove -f ../wt    ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-command      ~ command git worktree remove -f ../wt      ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-abs-path     ~ /usr/bin/git worktree remove -f ../wt     ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
wt-exe          ~ git.exe worktree remove -f ../wt          ~ - ~ deny|BG-GIT-WORKTREE-REMOVE-FORCE|worktree-remove-force
clean-dash-C    ~ git -C /x clean -f                        ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-dash-c    ~ git -c a.b=c clean -f                     ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-no-pager  ~ git --no-pager clean -f                   ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-env       ~ env FOO=1 git clean -f                    ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-command   ~ command git clean -f                      ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-abs-path  ~ /usr/bin/git clean -f                     ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
clean-exe       ~ git.exe clean -f                          ~ - ~ deny|BG-GIT-CLEAN-FORCE|clean-force
TABLE
case_end

# G14: the non-deny counterpart of G5. A detector that denies every wrapped push or clean would pass
# G5 alone, so an ordinary push and the dry-run cleans stay quiet in every launch form and wrapper.
case_begin "git-deviant-launch-forms-non-deny" "hooks/bash-guard/git-deviant.js"
bg_batched_stdin gd_rows G14 <<'TABLE'
push-dash-C     ~ git -C /x push origin feature-x           ~ - ~ passThrough|BG-NO-HIT|-
push-dash-c     ~ git -c a.b=c push origin feature-x        ~ - ~ passThrough|BG-NO-HIT|-
push-no-pager   ~ git --no-pager push origin feature-x      ~ - ~ passThrough|BG-NO-HIT|-
push-env        ~ env FOO=1 git push origin feature-x       ~ - ~ passThrough|BG-NO-HIT|-
push-command    ~ command git push origin feature-x         ~ - ~ passThrough|BG-NO-HIT|-
push-abs-path   ~ /usr/bin/git push origin feature-x        ~ - ~ passThrough|BG-NO-HIT|-
push-exe        ~ git.exe push origin feature-x             ~ - ~ passThrough|BG-NO-HIT|-
clean-n-dash-C    ~ git -C /x clean -n                      ~ - ~ passThrough|BG-NO-HIT|-
clean-n-dash-c    ~ git -c a.b=c clean -n                   ~ - ~ passThrough|BG-NO-HIT|-
clean-n-no-pager  ~ git --no-pager clean -n                 ~ - ~ passThrough|BG-NO-HIT|-
clean-n-env       ~ env FOO=1 git clean -n                  ~ - ~ passThrough|BG-NO-HIT|-
clean-n-command   ~ command git clean -n                    ~ - ~ passThrough|BG-NO-HIT|-
clean-n-abs-path  ~ /usr/bin/git clean -n                   ~ - ~ passThrough|BG-NO-HIT|-
clean-n-exe       ~ git.exe clean -n                        ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-dash-C   ~ git -C /x clean -nd                     ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-dash-c   ~ git -c a.b=c clean -nd                  ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-no-pager ~ git --no-pager clean -nd                ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-env      ~ env FOO=1 git clean -nd                 ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-command  ~ command git clean -nd                   ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-abs-path ~ /usr/bin/git clean -nd                  ~ - ~ passThrough|BG-NO-HIT|-
clean-nd-exe      ~ git.exe clean -nd                       ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G6: the interlock exception. The early write gate blocks Edit/Write only, so silencing git-deviant
# while it is armed would let `git push origin +main` reach the `git push origin *` allow rule with
# no settings.json row left to stop it. A non-deviant push and I1's compound stay quiet as before.
case_begin "git-deviant-interlock" "hooks/bash-guard/judge.js"
bg_batched_stdin gd_rows G6 <<'TABLE'
armed-plus-refspec ~ git push origin +main                    ~ ARMED ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
armed-plain-push   ~ git push -u origin feature/2572-feature-x ~ ARMED ~ passThrough|BG-INTERLOCK-QUIET|-
armed-I1-unchanged ~ git status && ls                         ~ ARMED ~ passThrough|BG-INTERLOCK-QUIET|-
armed-explicit-lease ~ git push --force-with-lease=main:@H40@ origin main ~ ARMED ~ passThrough|BG-INTERLOCK-QUIET|-
armed-multiline-plus ~ git status\ngit push origin +main      ~ ARMED ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
TABLE
case_end

# G17: `--prune` makes git delete remote refs that have no local counterpart, so it is the push-delete
# form; `--no-prune` is the opposite and stays quiet. A multi-line command is read line by line, so a
# deviant push after a harmless first line is still denied while a harmless pair is not.
case_begin "git-deviant-prune-multiline" "hooks/bash-guard/git-deviant/push.js"
bg_batched_stdin gd_rows G17 <<'TABLE'
prune-trail        ~ git push origin --prune                 ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
prune-lead         ~ git push --prune origin                 ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
prune-abbrev       ~ git push --prun origin                  ~ - ~ deny|BG-GIT-PUSH-DELETE|push-delete
no-prune           ~ git push --no-prune origin main         ~ - ~ passThrough|BG-NO-HIT|-
ml-plus-refspec    ~ git status\ngit push origin +main       ~ - ~ deny|BG-GIT-PUSH-PLUS-REFSPEC|push-plus-refspec
ml-force           ~ git status\ngit push -f                 ~ - ~ deny|BG-GIT-PUSH-FORCE|push-force
ml-harmless        ~ git status\ngit log                     ~ - ~ passThrough|BG-NO-HIT|-
TABLE
case_end

# G7: literal deny keeps precedence over git-deviant -- one message per deny, and the literal is
# what blocks a compound before any per-segment reading happens.
case_begin "git-deviant-literal-first" "hooks/bash-guard/judge.js"
bg_batched_stdin gd_rows G7 <<'TABLE'
chain-and-first  ~ git push -f origin x && ls ~ - ~ deny|BG-CHAIN-AND|chain-and
env-prefix-first ~ FOO=1 git push -f origin x ~ - ~ deny|BG-ENV-PREFIX|env-prefix
TABLE
case_end

# G8: the guidance. Each deny names its form and the way out, owned by rules/git.md, and never
# echoes the command back (the canary sits in a branch/path argument of every command).
case_begin "git-deviant-message" "hooks/bash-guard/message.js"
bg_batched_stdin g8_message_rows <<'TABLE'
force-headpush    ~ has ~ git push -f origin m9canary-br           ~ git push -u origin HEAD
force-lease       ~ has ~ git push -f origin m9canary-br           ~ --force-with-lease=<branch>:<
force-form        ~ has ~ git push -f origin m9canary-br           ~ push-force
force-owner       ~ has ~ git push -f origin m9canary-br           ~ rules/git.md
force-no-echo     ~ not ~ git push -f origin m9canary-br           ~ m9canary
plus-headpush     ~ has ~ git push origin +m9canary-br             ~ git push -u origin HEAD
plus-form         ~ has ~ git push origin +m9canary-br             ~ push-plus-refspec
plus-owner        ~ has ~ git push origin +m9canary-br             ~ rules/git.md
plus-no-echo      ~ not ~ git push origin +m9canary-br             ~ m9canary
delete-headpush   ~ has ~ git push origin :m9canary-br             ~ git push -u origin HEAD
delete-form       ~ has ~ git push origin :m9canary-br             ~ push-delete
delete-owner      ~ has ~ git push origin :m9canary-br             ~ rules/git.md
delete-no-echo    ~ not ~ git push origin :m9canary-br             ~ m9canary
matching-headpush ~ has ~ git push m9canary-remote :               ~ git push -u origin HEAD
matching-form     ~ has ~ git push m9canary-remote :               ~ push-matching-refspec
matching-owner    ~ has ~ git push m9canary-remote :               ~ rules/git.md
matching-no-echo  ~ not ~ git push m9canary-remote :               ~ m9canary
mirror-headpush   ~ has ~ git push --mirror m9canary-remote        ~ git push -u origin HEAD
mirror-form       ~ has ~ git push --mirror m9canary-remote        ~ push-mirror
mirror-owner      ~ has ~ git push --mirror m9canary-remote        ~ rules/git.md
mirror-no-echo    ~ not ~ git push --mirror m9canary-remote        ~ m9canary
lease-revparse    ~ has ~ git push --force-with-lease origin m9canary-br ~ git rev-parse origin/<branch>
lease-explicit    ~ has ~ git push --force-with-lease origin m9canary-br ~ <branch>:<
lease-owner       ~ has ~ git push --force-with-lease origin m9canary-br ~ rules/git.md
lease-no-echo     ~ not ~ git push --force-with-lease origin m9canary-br ~ m9canary
wt-sweep          ~ has ~ git worktree remove -f ../m9canary-wt    ~ /sweep-worktrees
wt-owner          ~ has ~ git worktree remove -f ../m9canary-wt    ~ rules/git.md
wt-no-echo        ~ not ~ git worktree remove -f ../m9canary-wt    ~ m9canary
clean-dry-run     ~ has ~ git clean -f m9canary-dir                ~ git clean -n
clean-owner       ~ has ~ git clean -f m9canary-dir                ~ rules/git.md
clean-no-echo     ~ not ~ git clean -f m9canary-dir                ~ m9canary
TABLE
case_end

# G9: the registries stay separate. REASON_CODES is the literal registry (F2/M4 pin its ten ids),
# so git-deviant codes must not leak into it; forms.js is their own frozen SSOT of exactly eight.
case_begin "git-deviant-registry" "hooks/bash-guard/git-deviant/forms.js"
ROWS=$((ROWS + 1))
assert_eq "G9: reason-codes is unchanged -- the ten literal codes only" \
    "BG-BACKTICK,BG-BRACE-GROUP,BG-CHAIN-AND,BG-CHAIN-SEMICOLON,BG-CMD-SUBST,BG-ENV-PREFIX,BG-HEREDOC,BG-PIPE,BG-REDIRECT-APPEND,BG-REDIRECT-OUT" \
    "$(probe reason-codes '')"
ROWS=$((ROWS + 1))
assert_not_contains "G9: no git-deviant code leaks into the literal reason-code registry" \
    "BG-GIT-" "$(probe reason-codes '')"
ROWS=$((ROWS + 1))
assert_eq "G9: forms.js is a frozen registry of exactly the eight git-deviant codes" \
    "BG-GIT-CLEAN-FORCE,BG-GIT-PUSH-DELETE,BG-GIT-PUSH-FORCE,BG-GIT-PUSH-LEASE-IMPLICIT,BG-GIT-PUSH-MATCHING-REFSPEC,BG-GIT-PUSH-MIRROR,BG-GIT-PUSH-PLUS-REFSPEC,BG-GIT-WORKTREE-REMOVE-FORCE" \
    "$(probe git-deviant-codes '')"
case_end

# G10: the real hook process. The in-process rows above would all pass even if hooks/bash-guard.js
# never turned a git-deviant verdict into the block envelope; only the wire format proves the deny.
case_begin "git-deviant-runtime-envelope" "hooks/bash-guard.js"
ROWS=$((ROWS + 1))
assert_eq "G10: a force push makes the hook process emit the block envelope" \
    "0|block" "$(bg_run Bash 'git push -f origin main')"
ROWS=$((ROWS + 1))
assert_eq "G10: a hyphen-f branch push leaves the decision to the host (no block)" \
    "0|passThrough-approve" "$(bg_run Bash 'git push -u origin feature/2572-feature-x')"
case_end

# G16: the guidance on the wire. G8 reads the judge's text and G10 only the envelope kind, so both
# would pass if hooks/bash-guard.js blocked with an empty or generic reason -- the #2120 failure
# mode, a deny that tells the model nothing. Each row runs the real hook process and asserts the
# way out from forms.js inside the decoded `reason` of a block envelope.
# g16_block_reason <command> -> the block reason, or a <NOT-BLOCK:...>/<NOT-JSON> sentinel.
# The node script is assembled from one-line pieces: a multi-line quoted string before a case
# marker makes the marker nesting uncertain for retire (bin/check-case-markers.sh).
G16_JS='const raw = require("fs").readFileSync(process.env.BG_OUT_FILE, "utf8"); let o;'
G16_JS+=' try { o = JSON.parse(raw); } catch (_e) { process.stdout.write("<NOT-JSON>"); process.exit(0); }'
G16_JS+=' if (o.decision !== "block" || typeof o.reason !== "string") process.stdout.write("<NOT-BLOCK:" + raw.trim().slice(0, 80) + ">");'
G16_JS+=' else process.stdout.write(o.reason);'
g16_block_reason() {
    bg_run_payload "$(bg_payload Bash "$1")" > /dev/null
    BG_OUT_FILE="$(node_path "$BG_RUNTIME_OUT")" node -e "$G16_JS" 2>/dev/null
}

# g16_rows: stdin table `name ~ command ~ fragment`.
g16_rows() {
    local name cmd frag
    while IFS='~' read -r name cmd frag; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        frag="$(mkcmd "$frag")"
        ROWS=$((ROWS + 1))

        assert_contains "G16/$name: the hook's block reason carries [$frag]" "$frag" "$(g16_block_reason "$cmd")"
    done
}

case_begin "git-deviant-runtime-guidance" "hooks/bash-guard.js"
g16_rows <<'TABLE'
push-force-lease    ~ git push --force origin main         ~ --force-with-lease=<branch>:<sha>
push-force-revparse ~ git push --force origin main         ~ git rev-parse origin/<branch>
push-force-code     ~ git push --force origin main         ~ [bash-guard BG-GIT-PUSH-FORCE]
wt-force-sweep      ~ git worktree remove --force ../wt    ~ /sweep-worktrees
clean-force-dry-run ~ git clean -f                         ~ git clean -n
TABLE
case_end

# SKIPPED: config-driven force (`git -c remote.origin.push=+refs/heads/* push`, remote.<n>.mirror).
# Because: out of scope by the NFR (one user, one PC) -- only deliberate evasion reaches it.
# SKIPPED: `git --exec-path push -f` (FLAGS_WITH_ARG reads push as the --exec-path value).
# Because: fixing FLAGS_WITH_ARG ripples into other hooks; recorded in the plan's Risks.
# SKIPPED: parse-failure fail-open for git-deviant (the settings.json floor is the only layer then).
# Because: the fail-open path is the bash-guard-wide named exception, pinned by cases-fail-open.sh.
