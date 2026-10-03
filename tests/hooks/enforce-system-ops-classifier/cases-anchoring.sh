#!/usr/bin/env bash
# Part of tests/hooks/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Sections S and W - where a command POSITION is recognized. Both sections
# probe the same seam from opposite sides: S asserts the separator anchor set
# shared by every category regex, W asserts the interpreter-body extractor that
# re-exposes text stripQuotedArgs would otherwise blank out.

# ===========================================================================
# Section S - separator / command-position anchoring. Every category regex is
# anchored with (?:^|[\s;|&]), so the anchor set itself is a shared surface:
# if one separator stopped anchoring, EVERY category would lose it at once.
# ===========================================================================
run_S_separators() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "S $name" "$want" "$(run_cmd "$cmd")"
done <<'TABLE'
sep-semicolon      | BLOCK | ls; winget install jq
sep-and            | BLOCK | ls && apt install jq
sep-pipe           | BLOCK | ls %PIPE% systemctl stop nginx
sep-leading-space  | BLOCK |    winget install jq
sep-cmdsubst       | BLOCK | echo "$(winget install jq)"
# Quoted TEXT is not a command: stripQuotedArgs blanks the span, so a mention of
# a blocked command inside an echo/grep argument must stay ALLOW. These are the
# false-positive guard for the anchor set above.
sep-echo-dq        | ALLOW | echo "winget install jq"
sep-echo-sq        | ALLOW | echo 'apt install jq'
sep-grep-mention   | ALLOW | grep -r "Restart-Computer" .
sep-glued-word     | ALLOW | mywinget install jq
sep-flag-glued     | ALLOW | --winget install jq
TABLE
}

# ===========================================================================
# Section W - interpreter wrapping. inlineBodiesOf() (hooks/lib/interpreter-
# inline-body.js) re-exposes the body of an interpreter inline-body invocation,
# which stripQuotedArgs would otherwise blank out. It splits logical lines only
# outside quotes (closed heredoc bodies removed first), scans every argv
# position for an interpreter or `eval`, and recurses into each body.
# Both directions are pinned. A quoted single-token argument (ssh / echo) is
# NOT executed locally, so its inner interpreter call stays ALLOW (iii).
# %NL% is a real newline inside the command text.
# ===========================================================================
w_verdict() { # w_verdict <command-text> -> verdict token (Bash tool)
    local esc nl='\n'
    esc="$(json_escape "$(expand_placeholders "$1")")"
    esc="${esc//%NL%/"$nl"}"
    run_json "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$esc\"}}" unset
}

run_W_wrapping() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "W $name" "$want" "$(w_verdict "$cmd")"
done <<'TABLE'
wrap-bash-c-dq          | BLOCK | bash -c "winget install jq"
wrap-bash-c-sq          | BLOCK | bash -c 'winget install jq'
wrap-sh-c-sq            | BLOCK | sh -c 'apt-get install jq'
wrap-zsh-c-sq           | BLOCK | zsh -c 'shutdown -h now'
wrap-pwsh-c-sq          | BLOCK | pwsh -c 'Stop-Service Spooler'
wrap-powershell-exe-c   | BLOCK | powershell.exe -c 'Stop-Service Spooler'
wrap-sudo-bash-c        | BLOCK | sudo bash -c 'mkfs.ext4 /dev/sdb1'
wrap-bash-c-after-semi  | BLOCK | ls; bash -c 'diskpart'
wrap-bash-c-second-stmt | BLOCK | bash -c 'echo hi; useradd bob'
wrap-bash-c-inner-clean | ALLOW | bash -c 'echo hello'
wrap-bash-c-empty-body  | ALLOW | bash -c ''
# --- combined short flag and pwsh long flag (#1861: formerly missed) ---
wrap-bash-lc-combined   | BLOCK | bash -lc 'useradd bob'
wrap-powershell-long    | BLOCK | powershell -Command "Stop-Service Spooler"
# --- (i) interpreter name / flag spellings ---
wrap-i-bash-lc-winget        | BLOCK | bash -lc 'winget install jq'
wrap-i-powershell-exe-noprof | BLOCK | powershell.exe -NoProfile -Command 'Stop-Computer'
wrap-i-quoted-interp-after-and | BLOCK | cd /tmp && "bash" -lc "shutdown -h now"
wrap-i-env-prefix-xc         | BLOCK | env FOO=1 bash -xc 'systemctl stop nginx'
wrap-i-nested-pwsh-in-bash   | BLOCK | bash -lc "pwsh -Command 'winget install jq'"
wrap-i-pwsh-upper-unquoted   | BLOCK | PowerShell -COMMAND winget install jq
wrap-i-bash-login-long-flag  | BLOCK | bash --login -c 'useradd bob'
wrap-i-bash-c-dashdash       | BLOCK | bash -c -- 'winget install jq'
wrap-i-bash-c-option-after   | BLOCK | bash -c -x 'useradd bob'
wrap-i-bash-c-plus-o-name    | BLOCK | bash -c +o pipefail 'shutdown -h now'
wrap-i-bash-c-shopt-O-name   | BLOCK | bash -c -O extglob 'shutdown -h now'
wrap-i-bash-c-shopt-plus-O   | BLOCK | bash -c +O extglob 'shutdown -h now'
wrap-i-fish-long-command     | BLOCK | fish --command 'shutdown -h now'
wrap-i-fish-long-command-eq  | BLOCK | fish --command='shutdown -h now'
wrap-i-ksh-c                 | BLOCK | ksh -c 'shutdown -h now'
wrap-i-mksh-c                | BLOCK | mksh -c 'useradd bob'
wrap-i-unparsed-trailing-apos | BLOCK | bash -c 'shutdown -h now' # it's fine
wrap-i-unparsed-nested-apos  | BLOCK | bash -c "sudo bash -c 'useradd bob'" # it's
wrap-i-unparsed-clean-body   | ALLOW | bash -c 'echo hi' # it's fine
wrap-i-echo-quoted-mention   | ALLOW | echo "bash -lc winget install jq"
wrap-i-bash-lc-clean-body    | ALLOW | bash -lc 'git status'
# --- (ii) heredoc removal, logical lines, every argv position, eval ---
wrap-ii-bash-c-nested-sudo   | BLOCK | bash -c 'sudo bash -lc "diskpart"'
wrap-ii-timeout-prefix       | BLOCK | timeout 5 bash -c 'useradd bob'
wrap-ii-xargs-prefix         | BLOCK | xargs bash -c 'winget install jq'
wrap-ii-exec-prefix          | BLOCK | exec bash -lc 'shutdown -h now'
wrap-ii-find-exec            | BLOCK | find . -exec bash -c 'systemctl stop nginx' \;
wrap-ii-eval-recursion       | BLOCK | eval "sudo bash -c 'winget install jq'"
wrap-ii-second-line          | BLOCK | ls%NL%bash -c 'winget install jq'
wrap-ii-bash-newline-in-sq   | BLOCK | bash -c '%NL%systemctl stop nginx%NL%'
wrap-ii-pwsh-newline-in-dq   | BLOCK | powershell -Command "%NL%Stop-Computer%NL%"
wrap-ii-line-continuation    | BLOCK | bash \%NL%  -c 'useradd bob'
wrap-ii-after-heredoc-apos   | BLOCK | git commit -F - <<'EOF'%NL%don't touch it%NL%EOF%NL%bash -c 'winget install jq'
wrap-ii-heredoc-to-interp    | BLOCK | bash <<'EOF'%NL%winget install jq%NL%EOF
# --- (iii) pinned ALLOW: quoted single-token args are not run locally ---
wrap-iii-ssh-remote-arg      | ALLOW | ssh host "sudo bash -c 'winget install jq'"
wrap-iii-echo-quoted-arg     | ALLOW | echo "x bash -c 'winget install jq'"
wrap-iii-commit-heredoc-body | ALLOW | git commit -F - <<'EOF'%NL%docs: explain bash -c 'winget install jq' wrapping%NL%EOF
wrap-iii-commit-heredoc-apos | ALLOW | git commit -F - <<'EOF'%NL%don't wrap it: bash -c "systemctl stop nginx"%NL%EOF
wrap-iii-pr-body-heredoc-apos | ALLOW | gh pr create --body-file - <<'EOF'%NL%It's about powershell -Command "Stop-Computer" detection%NL%EOF
TABLE
# (ii) runCommands array: commandTextOf joins the elements with "\n".
assert_eq "W wrap-ii-runcommands-later-element" "BLOCK" \
    "$(run_json '{"tool_name":"runCommands","tool_input":{"commands":["ls","bash -c '"'"'winget install jq'"'"'"]}}' unset)"
# 400 chained evals once grew bodies cubically and crashed the hook (OOM); the
# wrapped command must still be found, and an over-limit body set fails closed.
local evals="" i
for i in $(seq 1 400); do evals="${evals}eval "; done
assert_eq "W wrap-ii-eval-x400-blocks" "BLOCK" "$(w_verdict "${evals}winget install jq")"
assert_eq "W wrap-ii-eval-x400-clean" "ALLOW" "$(w_verdict "${evals}echo hi")"
local many="bash -c x"
for i in $(seq 1 1100); do many="${many} && bash -c x"; done
assert_eq "W wrap-ii-body-overflow-fails-closed" "BLOCK" "$(w_verdict "$many")"
# A quoted interpreter body still present at the recursion cap fails closed.
assert_eq "W wrap-ii-depth-cap-overflow-fails-closed" "BLOCK" \
    "$(w_verdict 'bash -c "bash -c \"bash -c \\\"bash -c '"'"'shutdown -h now'"'"'\\\"\""')"
assert_eq "W wrap-ii-depth-cap-three-levels-clean" "ALLOW" \
    "$(w_verdict 'bash -c "bash -c \"bash -c '"'"'echo hi'"'"'\""')"
}
