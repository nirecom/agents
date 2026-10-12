# shellcheck shell=bash
# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh outside any case span.
# --- pytest pre-fetch (issue #2501) ---
# Both dotfileslink installers warm uv's cache with pytest once, after the repo-visibility
# launcher is generated, so the test launcher never has to tell "uv cannot supply pytest" apart
# from a failing test. A failed pre-fetch is a warning only: the installer must carry on.

_PREFETCH_RE='uv[[:space:]]+run[[:space:]]+--no-project[[:space:]]+--with[[:space:]]+pytest[[:space:]]+python[[:space:]]+-c[[:space:]]'

# Line number of the first executable pre-fetch call (the tokens plus `import pytest`); empty when absent.
_prefetch_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE "$_PREFETCH_RE" "$file" | grep -F 'import pytest' \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Line number of the last executable repo-visibility launcher line; empty when absent.
_visibility_launcher_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -n 'repo-visibility' "$file" | grep -vE '^[0-9]+:[[:space:]]*#' | tail -n1 | cut -d: -f1
}

# _aborts <text> — true when <text>, quoted strings removed (a message may say "exit 1"), exits/returns/throws.
_aborts() {
    printf '%s\n' "$1" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g" \
        | grep -Eiq '(^|[[:space:];{(])(exit|return|throw)([[:space:];})]|$)'
}

# The pre-fetch exists and comes after the launcher generation.
_prefetch_after_launcher() {
    local p v
    p="$(_prefetch_line "$1")"
    v="$(_visibility_launcher_line "$1")"
    [ -n "$p" ] && [ -n "$v" ] && [ "$p" -gt "$v" ]
}

# POSIX: a failing pre-fetch cannot abort `set -e` and prints a warning. Accepted forms:
#   `if [!] uv run …; then … fi` whose block (to the first `fi`, at most 6 lines) warns and never exits/returns;
#   `uv run … || printf/echo …warn…` with no exit in the `||` tail.
_prefetch_warn_only_sh() {
    local file="$1" p line tail end block
    p="$(_prefetch_line "$file")"
    [ -n "$p" ] || return 1
    line="$(sed -n "${p}p" "$file")"
    if printf '%s' "$line" | grep -Eq '^[[:space:]]*if[[:space:]]'; then
        end="$(sed -n "$((p + 1)),$((p + 6))p" "$file" | grep -nE '^[[:space:]]*fi([[:space:]]|;|$)' | head -n1 | cut -d: -f1)"
        [ -n "$end" ] || return 1
        block="$(sed -n "${p},$((p + end))p" "$file")"
        printf '%s' "$block" | grep -Eq '[Ww]arn|WARN' || return 1
        _aborts "$block" && return 1
        return 0
    fi
    case "$line" in *'||'*) ;; *) return 1 ;; esac
    tail="${line#*import pytest}"
    case "$tail" in *'||'*) ;; *) return 1 ;; esac
    tail="${tail#*||}"
    printf '%s' "$tail" | grep -Eq '(printf|echo)' || return 1
    printf '%s' "$tail" | grep -Eq '[Ww]arn|WARN' || return 1
    _aborts "$tail" && return 1
    return 0
}

# PowerShell: the pre-fetch's $LASTEXITCODE is checked within 3 lines and a failure is a
# Write-Warning; nothing from the call to 4 lines after it throws or exits.
_prefetch_warn_only_ps() {
    local file="$1" p window
    p="$(_prefetch_line "$file")"
    [ -n "$p" ] || return 1
    window="$(sed -n "${p},$((p + 4))p" "$file")"
    sed -n "${p},$((p + 3))p" "$file" | grep -q '\$LASTEXITCODE' || return 1
    printf '%s' "$window" | grep -q 'Write-Warning' || return 1
    _aborts "$window" && return 1
    return 0
}

# _prefetch_probe <name> <detector> <file> <want 0|1> <what>: <detector> on <file> must return <want>.
_prefetch_probe() {
    local got=0
    "$2" "$3" && got=1
    if [ "$got" = "$4" ]; then pass "$1: $2 returns $got — $5"
    else fail "$1: $2 returned $got, expected $4 — $5"; fi
}
