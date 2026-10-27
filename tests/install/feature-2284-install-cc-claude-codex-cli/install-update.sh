#!/bin/bash
# tests/install/feature-2284-install-cc-claude-codex-cli/install-update.sh
# Sub-file: installer update integration tests (Groups C/D/E) and mutation probes.
# Static detectors check that each installer: (1) invokes its update (`cli update` or
# `npm install -g @openai/cli`, first executable match = update side), (2) gates it
# after wait-cc-exit (with skip on exit-1), (3) soft-fails on update failure, (4) scopes
# the guard AFTER the already-installed check (not at script top), (5) reaches the update
# even in the already-installed path.
# Tests: install/linux/claude-code.sh, install/win/claude-code.ps1, install/linux/codex.sh, install/win/codex.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
set -u
# Sourced by the dispatcher outside any case span: detector helpers only (cases run in its spans).

# ---------------------------------------------------------------------------
# Detector functions — each reads the file it receives on every call.
# ---------------------------------------------------------------------------

# First *executable* wait-cc-exit reference (comments excluded).
wait_ref_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'wait-cc-exit\.(sh|ps1)' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# First update invocation (`<cli> update` or `npm install -g @openai/<cli>`) written as an
# executable statement — the FIRST match in the file is the update side, so the install side's
# npm line (later in the file) never shadows it. A statement starts the line (optional `& `) or
# follows ; { ( && || then else do. A match inside a string (odd quote count before it), after a
# `#`, or against another package (`@openai/<cli>-other`) is not an invocation. One definition
# for every cli: no per-cli special case.
update_line() {
    local file="$1" cli="$2"
    [ -f "$file" ] || return 0
    awk -v cli="$cli" '
        BEGIN { body = "(" cli "[ \t]+update|npm[ \t]+install[ \t]+-g[ \t]+@openai/" cli ")([ \t]|$)" }
        {
            rest = $0; base = 0
            while (match(rest, body)) {
                pos = base + RSTART
                pre = substr($0, 1, pos - 1)
                prev = (pos > 1) ? substr($0, pos - 1, 1) : ""
                tmp = pre; dq = gsub("\"", "", tmp)
                tmp = pre; sq = gsub("\047", "", tmp)
                if (prev !~ "[-[:alnum:]_.@:/]" && dq % 2 == 0 && sq % 2 == 0 && index(pre, "#") == 0 &&
                    (pre ~ /^[ \t]*(&[ \t]+)?$/ ||
                     pre ~ /([;{(]|&&|\|\||(^|[ \t])(then|else|do))[ \t]*(&[ \t]+)?$/)) {
                    print NR; exit
                }
                base += RSTART; rest = substr(rest, RSTART + 1)
            }
        }
    ' "$file"
}

# awk helper shared by the PowerShell structure detectors: san() drops string contents and
# the trailing comment, so a token inside either never counts as code.
_PS_AWK_LIB='
function san(s,   i, c, out, dq, sq) {
    out = ""; dq = 0; sq = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (dq) { if (c == "\"") dq = 0; continue }
        if (sq) { if (c == "\047") sq = 0; continue }
        if (c == "\"") { dq = 1; continue }
        if (c == "\047") { sq = 1; continue }
        if (c == "#") break
        out = out c
    }
    return out
}
'

# Line of the already-installed detection (`type <cli>` / `Get-Command <cli>`).
already_installed_line() {
    local file="$1" cli="$2" kind="$3"
    [ -f "$file" ] || return 0
    if [ "$kind" = "sh" ]; then
        grep -nE "type[[:space:]]+${cli}([[:space:]]|\$)" "$file" | head -n1 | cut -d: -f1
    else
        grep -nE "Get-Command[[:space:]]+${cli}([[:space:]]|\)|\$)" "$file" | head -n1 | cut -d: -f1
    fi
}

# First `exit 0` after line $2, ignoring lines $3..$4 (the guard's own skip branch).
early_exit_line_after() {
    local file="$1" after="$2" skip_lo="${3:-0}" skip_hi="${4:-0}"
    awk -v after="$after" -v lo="$skip_lo" -v hi="$skip_hi" '
        NR > after && !(NR >= lo && NR <= hi) &&
        ($0 ~ /^[[:space:]]*exit[[:space:]]+0([[:space:]]|$)/ ||
         $0 ~ /[{;][[:space:]]*exit[[:space:]]+0([[:space:]]|\}|$)/) { print NR; exit }
    ' "$file"
}

# Guard line has its exit code bound to a branch (POSIX form).
sh_guard_result_is_bound() {
    local file="$1" wline
    wline="$(wait_ref_line "$file")"
    [ -n "$wline" ] || return 1
    sed -n "${wline}p" "$file" | grep -Eq '(^[[:space:]]*(if|while|until)[[:space:]]|\|\|)'
}

# Guard exit code bound in PowerShell: $LASTEXITCODE check or try/catch within 3 lines.
ps_guard_result_is_bound() {
    local file="$1" wline
    wline="$(wait_ref_line "$file")"
    [ -n "$wline" ] || return 1
    sed -n "$((wline > 3 ? wline - 3 : 1)),$((wline + 6))p" "$file" \
        | grep -Eq '(\$LASTEXITCODE|if[[:space:]]*\(|try[[:space:]]*\{|catch)'
}

# A skip (exit 0 / return) inside the guard's own branch, bounded to 6 lines.
_skip_between() {
    local file="$1" from="$2" before="$3" to
    to=$((from + 6))
    [ "$to" -ge "$before" ] && to=$((before - 1))
    [ "$to" -ge "$from" ] || return 1
    sed -n "${from},${to}p" "$file" \
        | grep -Eq '(exit[[:space:]]+0|(^|[[:space:]]|;|\{)return([[:space:]]|;|\}|$))'
}

# Soft-fail: `cli update … || true|:` pattern.
sh_update_soft_fails() {
    local file="$1" cli="$2"
    [ -f "$file" ] || return 1
    grep -Eq "${cli}[[:space:]]+update.*\|\|[[:space:]]*(true|:)" "$file"
}

# PowerShell soft-fail: failure caught ($LASTEXITCODE / try-catch) + warning, no throw.
ps_update_soft_fails() {
    local file="$1" cli="$2" line block
    line="$(update_line "$file" "$cli")"
    [ -n "$line" ] || return 1
    block="$(sed -n "${line},$((line + 8))p" "$file")"
    printf '%s\n' "$block" | grep -q 'throw' && return 1
    printf '%s\n' "$block" | grep -Eq \
        '(\$LASTEXITCODE|try[[:space:]]*\{|catch|SilentlyContinue|PSNativeCommandUseErrorActionPreference)' \
        || return 1
    printf '%s\n' "$block" | grep -Eq '(Write-Warning|SilentlyContinue)'
}

# Guard referenced before update (ordering).
update_is_gated() {
    local file="$1" cli="$2" wline uline
    wline="$(wait_ref_line "$file")"
    uline="$(update_line "$file" "$cli")"
    [ -n "$wline" ] && [ -n "$uline" ] && [ "$wline" -lt "$uline" ]
}

# Guard exit code actually consumed so a timeout skips the update.
update_is_skip_gated() {
    local file="$1" cli="$2" kind="$3" wline uline
    wline="$(wait_ref_line "$file")"
    uline="$(update_line "$file" "$cli")"
    [ -n "$wline" ] && [ -n "$uline" ] && [ "$wline" -lt "$uline" ] || return 1
    if [ "$kind" = "sh" ]; then
        sh_guard_result_is_bound "$file" || return 1
    else
        ps_guard_result_is_bound "$file" || return 1
    fi
    _skip_between "$file" "$wline" "$uline"
}

# "<first> <last>" of the guard's skip branch: the `if` consuming its exit code (sh `if !`
# on the guard line; ps `$LASTEXITCODE` within 3 lines) through its one-line end or `fi`/`}`.
guard_skip_range() {
    local file="$1" w="$2" kind="$3" i="" n line end
    if [ "$kind" = "sh" ]; then
        sed -n "${w}p" "$file" | grep -Eq '^[[:space:]]*if[[:space:]]+!' && i="$w"
    else
        for n in 1 2 3; do
            if sed -n "$((w + n))p" "$file" | grep -Eq '^[[:space:]]*if[[:space:]]*\(.*\$LASTEXITCODE'; then
                i=$((w + n)); break
            fi
        done
    fi
    [ -n "$i" ] || return 0
    line="$(sed -n "${i}p" "$file")"
    if printf '%s\n' "$line" | grep -Eq '(\{.*\}[[:space:]]*$|then.*(;|[[:space:]])fi([[:space:]]|;|$))'; then
        echo "$i $i"; return 0
    fi
    end="$(awk -v s="$i" 'NR > s && /^[[:space:]]*(fi|\})[[:space:]]*$/ { print NR; exit }' "$file")"
    [ -n "$end" ] && echo "$i $end"
    return 0
}

# Update reachable from already-installed path (not dead code after an early exit).
# Excludes only the skip branch of a guard between install check and update (#2476).
update_is_reachable_when_installed() {
    local file="$1" cli="$2" kind="$3" uline tline eline wline range lo=0 hi=0
    uline="$(update_line "$file" "$cli")"
    [ -n "$uline" ] || return 1
    tline="$(already_installed_line "$file" "$cli" "$kind")"
    [ -n "$tline" ] || return 0
    [ "$uline" -lt "$tline" ] && return 0
    wline="$(wait_ref_line "$file")"
    if [ -n "$wline" ] && [ "$wline" -gt "$tline" ] && [ "$wline" -lt "$uline" ]; then
        range="$(guard_skip_range "$file" "$wline" "$kind")"
        if [ -n "$range" ]; then lo="${range% *}"; hi="${range#* }"; fi
    fi
    eline="$(early_exit_line_after "$file" "$tline" "$lo" "$hi")"
    [ -n "$eline" ] || return 0
    [ "$uline" -lt "$eline" ]
}

# Guard must be scoped AFTER the already-installed check, not before it (HIGH-1).
# Placing the guard before the install check would skip new installs, not just updates.
update_guard_is_scoped() {
    local file="$1" cli="$2" kind="$3" wline tline
    wline="$(wait_ref_line "$file")"
    tline="$(already_installed_line "$file" "$cli" "$kind")"
    [ -n "$wline" ] && [ -n "$tline" ] && [ "$wline" -gt "$tline" ]
}

# Serial two-stage wait (PowerShell codex): between the wait reference and the update, an
# executable line names 'claude' and then 'codex' (claude first, so a claude timeout skips codex).
wait_covers_claude_then_codex() {
    local file="$1" wline uline
    wline="$(wait_ref_line "$file")"
    uline="$(update_line "$file" "codex")"
    [ -n "$wline" ] && [ -n "$uline" ] && [ "$wline" -lt "$uline" ] || return 1
    # The loop header naming both processes sits up to 3 lines above the helper call.
    sed -n "$((wline > 3 ? wline - 3 : 1)),${uline}p" "$file" | grep -vE '^[[:space:]]*#' \
        | grep -Eq "['\"]claude['\"][^#]*['\"]codex['\"]"
}

# The npm update runs only in the TRUE block of `if (Test-CodexUnderNpmPrefix ...) { ... }`:
# the guard line precedes the update, its condition is not negated, and the update sits
# between the guard's opening brace and the brace that closes it (an else side is outside).
# Coupled to that if/else shape: change the code form and this detector together.
update_requires_prefix_check() {
    local file="$1" uline
    uline="$(update_line "$file" "codex")"
    [ -n "$uline" ] || return 1
    [ "$(awk -v uline="$uline" "$_PS_AWK_LIB"'
        BEGIN { g = 0; depth = 0; closed = 0 }
        NR == uline { print (g && !closed && depth >= 1) ? 1 : 0; exit }
        {
            s = san($0)
            if (!g && s !~ /^[ \t]*function/ &&
                s ~ /(^|[^[:alnum:]_-])if[ \t]*\(.*Test-CodexUnderNpmPrefix/) {
                pre = s; sub(/Test-CodexUnderNpmPrefix.*/, "", pre)
                if (pre !~ /(-not|!)/) g = 1
            }
            if (g) {
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if (c == "{") depth++
                    else if (c == "}") { depth--; if (depth <= 0) closed = 1 }
                }
            }
        }
    ' "$file")" = "1" ]
}

# Structure, not order: the update sits inside a `try {` block whose closing `}` is followed
# at once (same line, or the next code line) by `catch`.
update_section_is_try_wrapped() {
    local file="$1" uline
    uline="$(update_line "$file" "codex")"
    [ -n "$uline" ] || return 1
    [ "$(awk -v uline="$uline" "$_PS_AWK_LIB"'
        BEGIN { n = 0; tgt = 0; ok = 0; pending = 0 }
        {
            s = san($0)
            if (pending && s ~ /[^ \t]/) { ok = (s ~ /^[ \t]*catch/) ? 1 : 0; pending = 0 }
            if (NR == uline) { for (k = n; k >= 1; k--) if (kind[k] == "try") { tgt = k; break } }
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "{") {
                    n++
                    kind[n] = (substr(s, 1, i - 1) ~ /(^|[^[:alnum:]_-])try[ \t]*$/) ? "try" : "o"
                } else if (c == "}" && n > 0) {
                    if (tgt > 0 && n == tgt) {
                        rest = substr(s, i + 1)
                        if (rest ~ /[^ \t]/) ok = (rest ~ /^[ \t]*catch/) ? 1 : 0
                        else pending = 1
                        tgt = 0
                    }
                    n--
                }
            }
        }
        END { print ok }
    ' "$file")" = "1" ]
}

# PowerShell codex structure (D4-7..9): serial wait, identity-guarded npm, try-wrapped
# update section.
check_codex_ps_update_group() {
    local label="$1" file="$2"

    if wait_covers_claude_then_codex "$file"; then
        pass "$label-7: wait helper runs claude then codex before the update (serial two-stage)"
    else
        fail "$label-7: wait helper does not cover claude then codex before the update"
    fi

    if update_requires_prefix_check "$file"; then
        pass "$label-8: npm update runs only in the true block of the Test-CodexUnderNpmPrefix guard"
    else
        fail "$label-8: npm update is not guarded by the true block of Test-CodexUnderNpmPrefix"
    fi

    if update_section_is_try_wrapped "$file"; then
        pass "$label-9: update section is inside try { } followed by catch"
    else
        fail "$label-9: update section is not wrapped by try { } catch"
    fi
}

check_update_group() {
    local label="$1" file="$2" cli="$3" kind="$4"

    if [ -n "$(update_line "$file" "$cli")" ]; then
        pass "$label-1: $(basename "$file") has an update invocation (\`$cli update\` / npm install -g @openai/$cli)"
    else
        fail "$label-1: $(basename "$file") has no update invocation (\`$cli update\` / npm install -g @openai/$cli)"
    fi

    if update_is_gated "$file" "$cli"; then
        pass "$label-2: update invocation is gated by wait-cc-exit (reference precedes it)"
    else
        fail "$label-2: update invocation has no preceding wait-cc-exit reference"
    fi

    if [ "$kind" = "sh" ]; then
        if sh_update_soft_fails "$file" "$cli"; then
            pass "$label-3: update invocation soft-fails (|| true / || :)"
        else
            fail "$label-3: update invocation failure is not soft-failed"
        fi
    else
        if ps_update_soft_fails "$file" "$cli"; then
            pass "$label-3: update invocation soft-fails (failure caught, warning, no throw)"
        else
            fail "$label-3: update invocation failure is not soft-failed"
        fi
    fi

    if update_is_skip_gated "$file" "$cli" "$kind"; then
        pass "$label-4: guard timeout skips the update invocation (exit code consumed, skip path present)"
    else
        fail "$label-4: guard timeout does not skip the update invocation (exit code ignored or no skip path)"
    fi

    if update_is_reachable_when_installed "$file" "$cli" "$kind"; then
        pass "$label-5: update invocation is reachable when $cli is already installed"
    else
        fail "$label-5: update invocation is dead code after the already-installed early exit"
    fi

    if update_guard_is_scoped "$file" "$cli" "$kind"; then
        pass "$label-6: wait-cc-exit guard is scoped after the install check (not at script top)"
    else
        fail "$label-6: wait-cc-exit guard precedes the install check — would skip new installs"
    fi
}

# CPR-ORTH: the update guard is symmetric across both platforms (one call per CLI).
orth_update_guard_pair() {
    local _cli="$1" _sh="$2" _ps="$3" _sh_ok=0 _ps_ok=0
    update_is_skip_gated "$_sh" "$_cli" "sh" && _sh_ok=1
    update_is_skip_gated "$_ps" "$_cli" "ps" && _ps_ok=1
    if [ "$_sh_ok" = "1" ] && [ "$_ps_ok" = "1" ]; then
        pass "ORTH: $_cli update is skip-guarded on both platforms (whatever the update invocation form)"
    else
        fail "ORTH: one-sided $_cli update guard (posix=$_sh_ok, win=$_ps_ok; both must be 1)"
    fi
}
