# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, ssh, security, injection, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced AFTER
# ssh-command-override.sh, whose _ssh_realgit_sandbox / _ssh_run_in_cwdrepo /
# _ssh_write_driver helpers it reuses. core.sshCommand is repo config: whoever can
# write .git/config chooses the value, so it is untrusted input (CWE-78). Every
# TC-SSH row feeds a benign value; these feed hostile ones.

# _sshinj_pwned <sandbox> — echoes the first injection marker found anywhere in
# the sandbox. Any hit means the value reached a shell, not just a test operand.
_sshinj_pwned() {
    find "$1" -name 'pwned*' 2>/dev/null | head -1
}

# _sshinj_case <label> <core.sshCommand value> <why-hostile>
# Every row is a NON-EMPTY value, so the contract is TC-SSH2's: classified as
# configured → GIT_SSH_COMMAND untouched (UNSET at the fetch). A classifier
# written `[ -z $(git config --get core.sshCommand) ]` — command substitution
# unquoted — word-splits the value into the `[` expression instead: `x -o -z`
# becomes `[ -z x -o -z ]`, whose `-o` disjunction is TRUE, flipping the row to
# the TC-SSH7 fallback and silently discarding the operator's transport.
_sshinj_case() {
    local label="$1" value="$2" why="$3"
    local sb; sb="$(_ssh_realgit_sandbox "$value" '-')"
    if [ -z "$sb" ]; then
        echo "SKIP: $label — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_sshinj.sh"; _ssh_write_driver "$drv"
    local out rc
    out="$(_ssh_run_in_cwdrepo "$sb" "$drv")"
    rc=$?
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    local marker; marker="$(_sshinj_pwned "$sb")"
    if [ -n "$marker" ]; then
        fail "$label: core.sshCommand='$value' ($why) was EXECUTED — injection marker '$marker' exists. The value must never reach a shell: quote it and compare it, never eval or expand it unquoted. Output: $out"
    elif [ "$rc" -ne 0 ]; then
        fail "$label: core.sshCommand='$value' ($why) made the sourcing shell exit $rc. Output: $out"
    elif [ "$got" = "UNSET" ]; then
        pass "$label: hostile-but-configured core.sshCommand ('$why') stays classified as configured, unexecuted"
    else
        fail "$label: the fetch saw GIT_SSH_COMMAND='$got' (expected 'UNSET' as in TC-SSH2 — the value IS configured). '$value' ($why) flipped the emptiness check, so the operator's transport was replaced by the BatchMode fallback — the classic unquoted-\$(...) test-expression corruption. Output: $out"
    fi
    rm -rf "$sb"
}

# The `$HOME` in the two execution probes is stored literally by git config; it
# only expands if an implementation eval's or re-expands the value, which is
# exactly what the marker detects. HOME is the sandbox home under every runner.
_sshinj_case "TC-SSHX1" '-o' \
    "reads as a test operator to an unquoted [ ... ]"
_sshinj_case "TC-SSHX2" 'x -o -z' \
    "classic [ ] disjunction payload that flips an unquoted -z check to true"
# shellcheck disable=SC2016  # $HOME stays literal on purpose — see the note above.
_sshinj_case "TC-SSHX3" 'ssh; touch $HOME/pwned' \
    "command chaining via ;"
# shellcheck disable=SC2016  # the substitution must NOT run here — only in a buggy impl.
_sshinj_case "TC-SSHX4" '$(touch $HOME/pwned)' \
    "command substitution"
_sshinj_case "TC-SSHX5" 'ssh -F "a b"' \
    "embedded space inside quotes — word-splitting bait"
_sshinj_case "TC-SSHX6" '  ssh -F padded  ' \
    "leading and trailing whitespace"
