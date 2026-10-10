# tests/feature-2134-bash-guard/cases-allow-self-script.sh
# Tests: hooks/bash-guard/allow.js, hooks/bash-guard/judge.js, hooks/lib/allow-command-list.js, hooks/lib/path-normalize.js, install/settings-allow-commands.txt, install/path-exposed-commands.txt
# Tags: hook, bash-guard, allow, self-script, cwd, path-normalize, scope:issue-specific, pwsh-not-required, TL2
# W1-W2: the self-script allow path (#2265). Sourced by the dispatcher.

# WHY THIS REPLACES THE GENERATED SPELLINGS. settings.json used to carry ~30 generated
# `Bash(...)` spellings per list entry; bash-guard now reads the two SSOT lists and answers
# permissionDecision "allow" itself. allow skips the prompt, so every negative below is a
# prompt that must survive: wrong interpreter, `..`, a separator, a redirect, an unverified cwd.

# W1 runs matchSelfScript() against a FIXTURE agents root (BG_PROBE_AGENTS_ROOT), so the rows
# never depend on what the real lists happen to contain. W2 is the real-list smoke at judge level.
FX_ROOT="$TMPROOT/fixture-agents"
mkdir -p "$FX_ROOT/install" "$FX_ROOT/bin/tool"
printf '%s\n' '# fixture allow list' 'bin/fx-bash' 'bin/fx-node.js' 'bin/tool/fx-sub' 'bin/fx-bare' \
    > "$FX_ROOT/install/settings-allow-commands.txt"
printf '%s\n' '# fixture PATH list' 'fx-bare' 'fx-unlisted' > "$FX_ROOT/install/path-exposed-commands.txt"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-bash"
printf '%s\n' '#!/usr/bin/env node' '0;' > "$FX_ROOT/bin/fx-node.js"
printf '%s\n' '#!/bin/bash' 'true' > "$FX_ROOT/bin/tool/fx-sub"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-bare"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-unlisted"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FX_ROOT/bin/fx-notlisted"

# Root spellings: M = forward-slash native, MSYS = /c/..., WIN = backslash. MSYS and WIN exist
# only on a drive-letter host; elsewhere those rows are skipped but still counted.
bg_root_forms() {
    local m="$1" drive rest
    BG_M="$m"; BG_MSYS=""; BG_WIN=""
    case "$m" in
        [A-Za-z]:/*) drive="${m%%:*}"; rest="${m#*:}"
                     BG_MSYS="/$(printf '%s' "$drive" | tr 'A-Z' 'a-z')$rest"; BG_WIN="${m//\//\\}" ;;
    esac
}
bg_root_forms "$(node_path "$FX_ROOT")"
FX_M="$BG_M"; FX_MSYS="$BG_MSYS"; FX_WIN="$BG_WIN"
bg_root_forms "$(node_path "$SCRIPT_CHECKOUT_ROOT")"
RL_M="$BG_M"; RL_MSYS="$BG_MSYS"; RL_WIN="$BG_WIN"

# bg_subst <text> <M> <MSYS> <WIN> -> text with @ROOT@ / @MSYS@ / @WIN@ replaced.
bg_subst() {
    local s="$1"
    s="${s//@ROOT@/$2}"; s="${s//@MSYS@/$3}"; s="${s//@WIN@/$4}"
    printf '%s' "$s"
}

# bg_cwd_json <token> <M> <MSYS> -> the JSON value for a cwd column; "" means "leave unset".
bg_cwd_json() {
    case "$1" in
        -) printf '' ;;
        ROOT) printf '"%s"' "$2" ;;
        MSYS) printf '"%s"' "$3" ;;
        OTHER) printf '"%s"' "$(node_path "$TMPROOT")" ;;
        *) printf '%s' "$1" ;;
    esac
}

bg_needs_drive() { case "$1" in *@MSYS@*|*@WIN@*|MSYS) return 0 ;; esac; return 1; }

w1_fixture_rows() {
    local name cmd cwd want got cwd_json
    while IFS='~' read -r name cmd cwd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        cwd="${cwd//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))
        if { bg_needs_drive "$cmd" || bg_needs_drive "$cwd"; } && [ -z "$FX_MSYS" ]; then
            skip "W1/$name: drive-letter spelling not applicable on this host"; continue
        fi
        cmd="$(bg_subst "$cmd" "$FX_M" "$FX_MSYS" "$FX_WIN")"
        cwd_json="$(bg_cwd_json "$cwd" "$FX_M" "$FX_MSYS")"
        got="$(BG_PROBE_AGENTS_ROOT="$FX_M" BG_PROBE_CTX_CWD_JSON="$cwd_json" probe self-script "$cmd")"
        assert_eq "W1/$name: matchSelfScript" "$want" "$got"
    done
}

# W1 rows are read from stdin (bg_batched_stdin) so each case below carries its own table.
# Positives are allow codes; `null` rows are permission prompts that must survive.
case_begin "self-script-fixture-interpreter" "hooks/bash-guard/allow.js"
bg_batched_stdin w1_fixture_rows <<'TABLE'
env-form        ~ bash "$AGENTS_MAIN_ROOT/bin/fx-bash" --x          ~ -     ~ BG-ALLOW-SELF-SCRIPT
env-braced      ~ bash "${AGENTS_MAIN_ROOT}/bin/fx-bash"            ~ -     ~ BG-ALLOW-SELF-SCRIPT
node-entry      ~ node "$AGENTS_MAIN_ROOT/bin/fx-node.js" a b       ~ -     ~ BG-ALLOW-SELF-SCRIPT
subdir-bin-bash ~ bash "$AGENTS_MAIN_ROOT/bin/tool/fx-sub"          ~ -     ~ BG-ALLOW-SELF-SCRIPT
bash-exe        ~ bash.exe "$AGENTS_MAIN_ROOT/bin/fx-bash"          ~ -     ~ BG-ALLOW-SELF-SCRIPT
abs-interp      ~ /usr/bin/bash "$AGENTS_MAIN_ROOT/bin/fx-bash"     ~ -     ~ BG-ALLOW-SELF-SCRIPT
interp-mismatch ~ node "$AGENTS_MAIN_ROOT/bin/fx-bash"              ~ -     ~ null
interp-mismatch2 ~ bash "$AGENTS_MAIN_ROOT/bin/fx-node.js"          ~ -     ~ null
other-interp    ~ sh "$AGENTS_MAIN_ROOT/bin/fx-bash"                ~ -     ~ null
or-suffix       ~ bash "$AGENTS_MAIN_ROOT/bin/fx-bash" || true      ~ -     ~ null
bg-suffix       ~ bash "$AGENTS_MAIN_ROOT/bin/fx-bash" &            ~ -     ~ null
redirect-in     ~ bash "$AGENTS_MAIN_ROOT/bin/fx-bash" < in.txt     ~ -     ~ null
exec-position   ~ "$AGENTS_MAIN_ROOT/bin/fx-bash"                   ~ -     ~ null
env-args-quoted ~ bash "$AGENTS_MAIN_ROOT/bin/fx-bash" --summary "a (b) c" --p "$HOME" ~ - ~ BG-ALLOW-SELF-SCRIPT
TABLE
case_end

# bashc-*: a single-quoted `bash -c` body is re-judged once, as one plain command or exactly
# `cd <root> && <command>`; any other shape inside it keeps the prompt.
case_begin "self-script-fixture-bash-c" "hooks/bash-guard/allow.js"
bg_batched_stdin w1_fixture_rows <<'TABLE'
bash-c-wrapper  ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/fx-bash"'    ~ -     ~ BG-ALLOW-SELF-SCRIPT
bashc-cd-env    ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/fx-bash"' ~ - ~ BG-ALLOW-SELF-SCRIPT
bashc-cd-rel    ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash bin/fx-bash' ~ -  ~ BG-ALLOW-SELF-SCRIPT
bashc-cd-root   ~ bash -c 'cd "@ROOT@" && node bin/fx-node.js'       ~ -     ~ BG-ALLOW-SELF-SCRIPT
bashc-bare      ~ bash -c 'fx-bare --x'                              ~ -     ~ BG-ALLOW-SELF-BARE
bashc-cd-bare   ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && fx-bare'       ~ -     ~ BG-ALLOW-SELF-BARE
bashc-rel-root  ~ bash -c 'bash bin/fx-bash'                         ~ ROOT  ~ BG-ALLOW-SELF-SCRIPT
bashc-nested    ~ bash -c 'bash -c fx-bare'                          ~ -     ~ null
bashc-two-seps  ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && fx-bare && fx-bare' ~ - ~ null
bashc-semicolon ~ bash -c 'cd "$AGENTS_MAIN_ROOT"; fx-bare'         ~ -     ~ null
bashc-pipe      ~ bash -c 'fx-bare | cat'                            ~ -     ~ null
bashc-redirect  ~ bash -c 'fx-bare > out.txt'                        ~ -     ~ null
bashc-subst     ~ bash -c 'bash "$(echo x)/bin/fx-bash"'             ~ -     ~ null
bashc-env-pfx   ~ bash -c 'FOO=1 fx-bare'                            ~ -     ~ null
bashc-cd-other  ~ bash -c 'cd /usr && bash bin/fx-bash'              ~ -     ~ null
bashc-cd-dot    ~ bash -c 'cd . && bash bin/fx-bash'                 ~ ROOT  ~ null
bashc-cd-last   ~ bash -c 'fx-bare && cd "$AGENTS_MAIN_ROOT"'       ~ -     ~ null
bashc-extra-arg ~ bash -c 'fx-bare' extra                            ~ -     ~ null
bashc-dquoted   ~ bash -c "fx-bare"                                  ~ -     ~ null
bashc-exec-pos  ~ bash -c '"$AGENTS_MAIN_ROOT/bin/fx-bash"'         ~ -     ~ null
bashc-unlisted  ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/fx-notlisted"' ~ -   ~ null
sh-c-wrapper    ~ sh -c 'fx-bare'                                    ~ -     ~ null
bashc-cd-lookalike ~ bash -c 'cd "@ROOT@-evil" && bash bin/fx-bash'  ~ -     ~ null
TABLE
case_end

# root-lookalike: the root must be stripped on a path BOUNDARY, or `<root>-evil/bin/x` would
# normalize to an entry. abs-bad-cwd: an absolute or $AGENTS_MAIN_ROOT form never reads cwd.
case_begin "self-script-fixture-path-forms" "hooks/lib/path-normalize.js"
bg_batched_stdin w1_fixture_rows <<'TABLE'
abs-root        ~ bash "@ROOT@/bin/fx-bash"                          ~ -     ~ BG-ALLOW-SELF-SCRIPT
win-root        ~ bash "@WIN@\bin\fx-bash"                           ~ -     ~ BG-ALLOW-SELF-SCRIPT
msys-root       ~ bash "@MSYS@/bin/fx-bash"                          ~ -     ~ BG-ALLOW-SELF-SCRIPT
rel-at-root     ~ bash bin/fx-bash                                   ~ ROOT  ~ BG-ALLOW-SELF-SCRIPT
abs-bad-cwd     ~ bash "@ROOT@/bin/fx-bash"                          ~ OTHER ~ BG-ALLOW-SELF-SCRIPT
dotdot          ~ bash "$AGENTS_MAIN_ROOT/bin/../bin/fx-bash"       ~ -     ~ null
rel-other-cwd   ~ bash bin/fx-bash                                   ~ OTHER ~ null
rel-no-cwd      ~ bash bin/fx-bash                                   ~ -     ~ null
root-lookalike  ~ bash "@ROOT@-evil/bin/fx-bash"                     ~ -     ~ null
TABLE
case_end

case_begin "self-script-fixture-list-membership" "hooks/lib/allow-command-list.js"
bg_batched_stdin w1_fixture_rows <<'TABLE'
bare-exposed    ~ fx-bare --x                                        ~ -     ~ BG-ALLOW-SELF-BARE
not-listed      ~ bash "$AGENTS_MAIN_ROOT/bin/fx-notlisted"         ~ -     ~ null
bare-unexposed  ~ fx-bash                                            ~ -     ~ null
bare-unlisted   ~ fx-unlisted                                        ~ -     ~ null
TABLE
case_end

w2_real_rows() {
    local name cmd tcwd icwd want got tj ij
    while IFS='~' read -r name cmd tcwd icwd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"; tcwd="$(mkcmd "$tcwd")"; icwd="$(mkcmd "$icwd")"
        ROWS=$((ROWS + 1))
        if { bg_needs_drive "$cmd" || bg_needs_drive "$tcwd" || bg_needs_drive "$icwd"; } && [ -z "$RL_MSYS" ]; then
            skip "W2/$name: drive-letter spelling not applicable on this host"; continue
        fi
        cmd="$(bg_subst "$cmd" "$RL_M" "$RL_MSYS" "$RL_WIN")"
        tj="$(bg_cwd_json "$tcwd" "$RL_M" "$RL_MSYS")"; ij="$(bg_cwd_json "$icwd" "$RL_M" "$RL_MSYS")"
        got="$(BG_PROBE_TOOL_CWD_JSON="$tj" BG_PROBE_INPUT_CWD_JSON="$ij" verdict_code_of "$cmd")"
        assert_eq "W2/$name: verdict|code" "$want" "$got"
    done
}

case_begin "self-script-real-settings-list" "install/settings-allow-commands.txt"
bg_batched_stdin w2_real_rows <<'TABLE'
node-next-step     ~ node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list ~ -       ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
bash-confirm-off   ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" RUN_TL4 on    ~ -       ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
real-mismatch      ~ bash "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list ~ -       ~ -    ~ passThrough|BG-NO-HIT
handoff-append     ~ node "$AGENTS_MAIN_ROOT/bin/workflow/handoff-append" --class A --summary "a (b) c" ~ - ~ - ~ allow|BG-ALLOW-SELF-SCRIPT
TABLE
case_end

case_begin "self-script-real-path-exposed" "install/path-exposed-commands.txt"
bg_batched_stdin w2_real_rows <<'TABLE'
bare-path-exposed  ~ review-code-codex --help                                ~ -       ~ -    ~ allow|BG-ALLOW-SELF-BARE
TABLE
case_end

# rel-blank-tool-cwd: a whitespace-only tool_input.cwd is skipped, so input.cwd is used.
# rel-tool-cwd-wins: tool_input.cwd is read first; a valid non-root value is not overridden.
# Non-string, relative or absent cwd never resolves a relative form (no process.cwd() guess).
case_begin "self-script-real-cwd-resolution" "hooks/bash-guard/judge.js"
bg_batched_stdin w2_real_rows <<'TABLE'
rel-tool-cwd       ~ node bin/workflow/next-step --list                      ~ ROOT    ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
rel-input-cwd      ~ node bin/workflow/next-step --list                      ~ -       ~ ROOT ~ allow|BG-ALLOW-SELF-SCRIPT
rel-msys-cwd       ~ node bin/workflow/next-step --list                      ~ MSYS    ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
rel-blank-tool-cwd ~ node bin/workflow/next-step --list                      ~ "   "   ~ ROOT ~ allow|BG-ALLOW-SELF-SCRIPT
rel-tool-cwd-wins  ~ node bin/workflow/next-step --list                      ~ OTHER   ~ ROOT ~ passThrough|BG-NO-HIT
rel-no-cwd         ~ node bin/workflow/next-step --list                      ~ -       ~ -    ~ passThrough|BG-NO-HIT
rel-numeric-cwd    ~ node bin/workflow/next-step --list                      ~ 42      ~ -    ~ passThrough|BG-NO-HIT
rel-object-cwd     ~ node bin/workflow/next-step --list                      ~ {"p":"x"} ~ -  ~ passThrough|BG-NO-HIT
rel-relative-cwd   ~ node bin/workflow/next-step --list                      ~ "bin"   ~ -    ~ passThrough|BG-NO-HIT
env-bad-cwd        ~ node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list ~ 42      ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
abs-bad-cwd        ~ node "@ROOT@/bin/workflow/next-step" --list             ~ "bin"   ~ -    ~ allow|BG-ALLOW-SELF-SCRIPT
TABLE
case_end

# bashc-inner-*: the inner body only chooses allow vs passThrough; it never escalates to deny
# or notify. bashc-outer-and: a separator OUTSIDE the quotes is still judged as before.
# arg-*: an unsafe construct in an ARGUMENT (not the script path) never earns allow; plain
# forms keep their existing deny, and an embedded newline (quoted or bare) keeps the prompt.
# bashc-git-*: a read-only body that is not a self-script is not unwrapped for the read-only allow.
case_begin "self-script-real-bash-c-and-args" "hooks/bash-guard/judge.js"
bg_batched_stdin w2_real_rows <<'TABLE'
bashc-cd-real      ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" CONFIRM_X on' ~ - ~ - ~ allow|BG-ALLOW-SELF-SCRIPT
bashc-inner-pipe   ~ bash -c 'review-code-codex --help | cat'                ~ -       ~ -    ~ passThrough|BG-NO-HIT
bashc-inner-exec   ~ bash -c '"$AGENTS_MAIN_ROOT/bin/confirm-off" X on'     ~ -       ~ -    ~ passThrough|BG-NO-HIT
bashc-outer-and    ~ bash -c 'review-code-codex' && true                     ~ -       ~ -    ~ deny|BG-CHAIN-AND
arg-subst          ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "$(echo x)" on ~ -      ~ -    ~ deny|BG-CMD-SUBST
arg-subst-bashc    ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "$(echo x)" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-subst-bashc-cd ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "$(echo x)" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-btick          ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "`echo x`" on ~ -       ~ -    ~ deny|BG-BACKTICK
arg-btick-bashc    ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "`echo x`" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-btick-bashc-cd ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "`echo x`" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-qnl            ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "a\nb" on     ~ -       ~ -    ~ passThrough|BG-NO-HIT
arg-qnl-bashc      ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "a\nb" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-qnl-bashc-cd   ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" "a\nb" on' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-nlsep          ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on\nrm -f x ~ -       ~ -    ~ passThrough|BG-NO-HIT
arg-nlsep-bashc    ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on\nrm -f x' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-nlsep-bashc-cd ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on\nrm -f x' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-heredoc        ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on <<EOF\nx\nEOF ~ -  ~ -    ~ deny|BG-HEREDOC
arg-heredoc-bashc  ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on <<EOF\nx\nEOF' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-heredoc-bashc-cd ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on <<EOF\nx\nEOF' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-redir-in       ~ bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on < in.txt ~ -       ~ -    ~ passThrough|BG-NO-HIT
arg-redir-in-bashc ~ bash -c 'bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on < in.txt' ~ - ~ - ~ passThrough|BG-NO-HIT
arg-redir-in-bashc-cd ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" X on < in.txt' ~ - ~ - ~ passThrough|BG-NO-HIT
bashc-git-status   ~ bash -c 'git status'                                    ~ -       ~ -    ~ passThrough|BG-NO-HIT
bashc-cd-git-log   ~ bash -c 'cd "$AGENTS_MAIN_ROOT" && git log --oneline -5' ~ -    ~ -    ~ passThrough|BG-NO-HIT
TABLE
# arg-crsep-bashc: a CR in the body keeps the prompt like a newline; mkcmd cannot carry \r, so
# off-table. Built outside $(...): Git Bash drops a $'\r' written inside a command substitution.
BG_CR=$'\r'
BG_CRSEP_CMD="bash -c 'bash \"\$AGENTS_MAIN_ROOT/bin/confirm-off\" X on${BG_CR}rm -f x'"
ROWS=$((ROWS + 1))
assert_eq "W2/arg-crsep-bashc: the command text really carries a CR (vacuity guard)" \
    "yes" "$([[ "${#BG_CR}" == 1 && "$BG_CRSEP_CMD" == *"$BG_CR"* ]] && echo yes || echo no)"
assert_eq "W2/arg-crsep-bashc: verdict|code" "passThrough|BG-NO-HIT" "$(verdict_code_of "$BG_CRSEP_CMD")"
case_end

# F1 (#2265 review_security): an unrelated dir whose one-line `.git` FILE names a nonexistent
# <real common dir>/worktrees/<name> is not a linked worktree of the agents checkout, so a
# script listed in ITS OWN install/settings-allow-commands.txt must not earn allow. Nothing is
# written under the real common dir; the forged gitdir path is only named, never created.
FG_ROOT="$TMPROOT/f1-forged-agents"
mkdir -p "$FG_ROOT/install" "$FG_ROOT/bin"
printf '%s\n' '# forged allow list' 'bin/fg-x' > "$FG_ROOT/install/settings-allow-commands.txt"
: > "$FG_ROOT/install/path-exposed-commands.txt"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FG_ROOT/bin/fg-x"
FG_COMMON="$(git -C "$SCRIPT_CHECKOUT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
FG_GHOST="$(node_path "${FG_COMMON:-/nonexistent}")/worktrees/bg-f1-ghost-${TMPROOT##*.}"
printf 'gitdir: %s\n' "$FG_GHOST" > "$FG_ROOT/.git"
FG_M="$(node_path "$FG_ROOT")"

case_begin "self-script-forged-gitdir-checkout" "hooks/bash-guard/judge.js"
assert_eq "F1 vacuity: the agents checkout's common dir was resolved" "yes" \
    "$([[ -n "$FG_COMMON" && -d "$FG_COMMON" ]] && echo yes || echo no)"
assert_eq "F1 vacuity: the forged gitdir really does not exist" "absent" \
    "$([[ -e "$FG_GHOST" ]] && echo present || echo absent)"
ROWS=$((ROWS + 2))
assert_eq "W2/f1-forged-abs: verdict|code" "passThrough|BG-NO-HIT" \
    "$(verdict_code_of "bash \"$FG_M/bin/fg-x\"")"
assert_eq "W2/f1-forged-bashc-cd: verdict|code" "passThrough|BG-NO-HIT" \
    "$(verdict_code_of "bash -c 'cd \"$FG_M\" && bash bin/fg-x'")"
case_end

# Same fixture shape, differing only in genuineness: a git-initialized fixture agents root whose
# REAL linked worktree carries the identical list + script is allow (control), while the forged
# twin against that same root is not. So the forged rows above fail on identity, not on shape.
GF_MAIN="$TMPROOT/f1-genuine-agents"; GF_WT="$TMPROOT/f1-genuine-wt"; GF_FORGED="$TMPROOT/f1-forged-twin"
for gf_dir in "$GF_MAIN" "$GF_FORGED"; do
    mkdir -p "$gf_dir/install" "$gf_dir/bin"
    cp "$FG_ROOT/install/settings-allow-commands.txt" "$FG_ROOT/install/path-exposed-commands.txt" "$gf_dir/install/"
    cp "$FG_ROOT/bin/fg-x" "$gf_dir/bin/fg-x"
done
harness_git_init "$GF_MAIN"
git -C "$GF_MAIN" config core.autocrlf false
git -C "$GF_MAIN" add -A
git -C "$GF_MAIN" -c user.email=fixture@example.com -c user.name=fixture commit -qm fixture
git -C "$GF_MAIN" worktree add -q "$GF_WT" 2>/dev/null
printf 'gitdir: %s\n' "$(node_path "$GF_MAIN/.git/worktrees")/ghost-twin" > "$GF_FORGED/.git"
GF_MAIN_M="$(node_path "$GF_MAIN")"; GF_WT_M="$(node_path "$GF_WT")"; GF_FORGED_M="$(node_path "$GF_FORGED")"

case_begin "self-script-genuine-worktree-vs-forged-twin" "hooks/bash-guard/allow.js"
assert_eq "F1 vacuity: the genuine worktree carries the listed script" "yes" \
    "$([[ -f "$GF_WT/bin/fg-x" && -f "$GF_WT/.git" ]] && echo yes || echo no)"
ROWS=$((ROWS + 3))
assert_eq "W1/f1-genuine-wt-abs: matchSelfScript" "BG-ALLOW-SELF-SCRIPT" \
    "$(BG_PROBE_AGENTS_ROOT="$GF_MAIN_M" probe self-script "bash \"$GF_WT_M/bin/fg-x\"")"
assert_eq "W1/f1-genuine-wt-bashc-cd: matchSelfScript" "BG-ALLOW-SELF-SCRIPT" \
    "$(BG_PROBE_AGENTS_ROOT="$GF_MAIN_M" probe self-script "bash -c 'cd \"$GF_WT_M\" && bash bin/fg-x'")"
assert_eq "W1/f1-forged-twin-abs: matchSelfScript" "null" \
    "$(BG_PROBE_AGENTS_ROOT="$GF_MAIN_M" probe self-script "bash \"$GF_FORGED_M/bin/fg-x\"")"
ROWS=$((ROWS + 1))
assert_eq "W1/f1-forged-twin-bashc-cd: matchSelfScript" "null" \
    "$(BG_PROBE_AGENTS_ROOT="$GF_MAIN_M" probe self-script "bash -c 'cd \"$GF_FORGED_M\" && bash bin/fg-x'")"
case_end

# The `.git` DIRECTORY form of the forgery: a twin whose `.git` is a directory link to the
# FIXTURE root's .git (never the real repo's, so the tmp cleanup cannot reach outside TMPROOT).
GF_JUNC="$TMPROOT/f1-junction-twin"
mkdir -p "$GF_JUNC/install" "$GF_JUNC/bin"
cp "$FG_ROOT/install/settings-allow-commands.txt" "$FG_ROOT/install/path-exposed-commands.txt" "$GF_JUNC/install/"
cp "$FG_ROOT/bin/fg-x" "$GF_JUNC/bin/fg-x"
GF_JUNC_M="$(node_path "$GF_JUNC")"

case_begin "self-script-linked-dot-git-twin" "hooks/bash-guard/allow.js"
ROWS=$((ROWS + 1))
if run_with_timeout 30 node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "junction")' \
    "$(node_path "$GF_MAIN/.git")" "$GF_JUNC_M/.git" 2>/dev/null; then
    assert_eq "W1/f1-junction-twin-abs: matchSelfScript" "null" \
        "$(BG_PROBE_AGENTS_ROOT="$GF_MAIN_M" probe self-script "bash \"$GF_JUNC_M/bin/fg-x\"")"
else
    skip "W1/f1-junction-twin-abs: directory link creation failed on this host"
fi
case_end
