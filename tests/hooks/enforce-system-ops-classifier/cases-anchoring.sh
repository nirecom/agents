#!/usr/bin/env bash
# Part of tests/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
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
# Section W - interpreter wrapping. getInnerBodies() re-exposes the body of an
# `<interpreter> ... -c '<body>'` invocation, which stripQuotedArgs would
# otherwise blank out entirely. Both directions are pinned: the shapes it
# reaches, and the shapes it does NOT.
#
# The ALLOW rows marked "(current behaviour)" are NOT an endorsement — they are
# recorded so the reach of getInnerBodies() is visible and any widening of the
# regex is a deliberate, test-visible change rather than an accident. The regex
# requires a literal `-c` followed by whitespace and an opening quote, so
# `bash -lc '...'` (combined flag) and `powershell -Command "..."` (long flag)
# are both outside it today.
# ===========================================================================
run_W_wrapping() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "W $name" "$want" "$(run_cmd "$cmd")"
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
# --- outside the getInnerBodies() regex today (current behaviour, pinned) ---
wrap-bash-lc-combined   | ALLOW | bash -lc 'useradd bob'
wrap-powershell-long    | ALLOW | powershell -Command "Stop-Service Spooler"
TABLE
}
