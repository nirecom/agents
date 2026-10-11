#!/bin/bash
# hooks/lib/load-env.sh
#
# Bash-side .env loader shared by git hooks; hooks/lib/load-env.js is the reference grammar.
# Source-only: defines functions so a test can exercise it without entrypoint side effects.
# Usage: `. "$(dirname "$0")/lib/load-env.sh"; _load_env_file`.
# Settings root: a non-blank $AGENTS_MAIN_ROOT (never falls through), else the first of this
# checkout's logical and physical roots that holds a .env. A non-empty export beats .env.
# Intended differences from js: a multi-line quoted value is dropped with a warning, an OS
# block is dropped when the filter did not run, and there is no .env.local overlay.

_LOAD_ENV_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_load_env_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_load_env_lib_dir" != "${BASH_SOURCE[0]}" ] || _load_env_lib_dir="."
_LOAD_ENV_SCRIPT_CHECKOUT_ROOT_PHYSICAL="$(cd -P "$_load_env_lib_dir" && cd -P ../.. && pwd -P)" || _LOAD_ENV_SCRIPT_CHECKOUT_ROOT_PHYSICAL=""
unset _load_env_lib_dir

# Sets _LOAD_ENV_CFG (settings root) and _LOAD_ENV_FILTER (env-os-filter path, or empty)
# without a subshell. The .env belongs to the settings root; the filter to an agents checkout.
_load_env_resolve() {
    local root="${AGENTS_MAIN_ROOT:-}" c
    root="${root#"${root%%[![:space:]]*}"}"
    root="${root%"${root##*[![:space:]]}"}"
    _LOAD_ENV_CFG="$root"
    if [ -z "$root" ]; then
        _LOAD_ENV_CFG="$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT"
        for c in "$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT" "$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT_PHYSICAL"; do
            if [ -n "$c" ] && [ -r "$c/.env" ]; then
                _LOAD_ENV_CFG="$c"
                break
            fi
        done
    fi
    _LOAD_ENV_FILTER=""
    for c in "$_LOAD_ENV_CFG" "$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT" "$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT_PHYSICAL"; do
        if [ -n "$c" ] && [ -x "$c/bin/env-os-filter" ]; then
            _LOAD_ENV_FILTER="$c/bin/env-os-filter"
            break
        fi
    done
    return 0
}

_load_env_cfg_dir() {
    _load_env_resolve
    printf '%s' "$_LOAD_ENV_CFG"
}

# Mirrors findClosingQuote: inside double quotes a backslash escapes the next character.
_load_env_find_close() {
    local text="$1" quote="$2" i=0 n=${#1} ch
    _LOAD_ENV_CLOSE=-1
    while [ "$i" -lt "$n" ]; do
        ch="${text:i:1}"
        if [ "$quote" = '"' ] && [ "$ch" = "\\" ]; then
            i=$((i + 2))
            continue
        fi
        if [ "$ch" = "$quote" ]; then
            _LOAD_ENV_CLOSE=$i
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

_load_env_unescape_dq() {
    local s="$1" out="" i=0 n=${#1} ch nx
    while [ "$i" -lt "$n" ]; do
        ch="${s:i:1}"
        if [ "$ch" != "\\" ] || [ "$i" -eq $((n - 1)) ]; then
            out="$out$ch"
            i=$((i + 1))
            continue
        fi
        nx="${s:i+1:1}"
        case "$nx" in
            n) out="$out"$'\n' ;;
            t) out="$out"$'\t' ;;
            "\\") out="$out\\" ;;
            '"') out="$out\"" ;;
            *) out="$out\\$nx" ;;
        esac
        i=$((i + 2))
    done
    _LOAD_ENV_UNESC="$out"
}

# Reads filtered .env text on stdin into _LOAD_ENV_KEYS / _LOAD_ENV_VALS in file order.
# Warnings name the key only: the value it guarded is exactly what must not leak.
_load_env_parse() {
    local raw line key val q rest depth=0 os_warned=0 skip_key="" skip_q=""
    while IFS= read -r raw || [ -n "$raw" ]; do
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            '#@if '*)
                if [ "$os_warned" -eq 0 ]; then
                    printf 'load-env.sh: OS filter did not run — #@if blocks dropped\n' >&2
                    os_warned=1
                fi
                depth=$((depth + 1))
                continue ;;
            '#@endif')
                if [ "$depth" -gt 0 ]; then depth=$((depth - 1)); fi
                continue ;;
            '#@'*) continue ;;
        esac
        if [ "$depth" -gt 0 ]; then continue; fi
        if [ -n "$skip_key" ]; then
            if _load_env_find_close "$line" "$skip_q"; then
                printf 'load-env.sh: %s discarded — multi-line quoted value not supported\n' "$skip_key" >&2
                skip_key=""
            fi
            continue
        fi
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$val" in
            '"'*|"'"*)
                q="${val:0:1}"
                rest="${val:1}"
                if ! _load_env_find_close "$rest" "$q"; then
                    skip_key="$key"
                    skip_q="$q"
                    continue
                fi
                val="${rest:0:_LOAD_ENV_CLOSE}"
                if [ "$q" = '"' ]; then
                    _load_env_unescape_dq "$val"
                    val="$_LOAD_ENV_UNESC"
                fi ;;
        esac
        _LOAD_ENV_KEYS+=("$key")
        _LOAD_ENV_VALS+=("$val")
    done
    if [ -n "$skip_key" ]; then
        printf 'load-env.sh: %s discarded — unterminated quote\n' "$skip_key" >&2
    fi
    return 0
}

_load_env_records() {
    local envfile="$1" filter="$2"
    _LOAD_ENV_KEYS=()
    _LOAD_ENV_VALS=()
    # Process substitution, not a pipe: the loop must fill the arrays in THIS shell.
    if [ -n "$filter" ] && [ -x "$filter" ]; then
        _load_env_parse < <("$filter" "$envfile")
    else
        _load_env_parse < "$envfile"
    fi
}

_load_env_lookup() {
    local envfile="$1" key="$2" filter="$3" i=0
    _LOAD_ENV_FOUND=""
    _load_env_records "$envfile" "$filter"
    while [ "$i" -lt "${#_LOAD_ENV_KEYS[@]}" ]; do
        if [ "${_LOAD_ENV_KEYS[$i]}" = "$key" ]; then _LOAD_ENV_FOUND="${_LOAD_ENV_VALS[$i]}"; fi
        i=$((i + 1))
    done
    _LOAD_ENV_KEYS=()
    _LOAD_ENV_VALS=()
    return 0
}

# _load_env_only_scan <envfile> <key> <filter> — the last value KEY carries in that file.
_load_env_only_scan() {
    _load_env_lookup "$1" "$2" "$3"
    printf '%s' "$_LOAD_ENV_FOUND"
    _LOAD_ENV_FOUND=""
}

# _load_env_only_value <KEY[:-DEFAULT]> — the value KEY carries in the settings root's .env,
# or DEFAULT when the file, the key, or its value is absent. The ambient environment must
# NOT answer: a value that decides whether a guard blocks would otherwise be bypassed by a
# one-word `VAR=off git commit`. Mirrors readDefaultEnvFile() in hooks/lib/load-env.js.
_load_env_only_value() {
    local spec="$1" key def out=""
    key="${spec%%:-*}"
    if [ "$key" = "$spec" ]; then def=""; else def="${spec#*:-}"; fi
    _load_env_resolve
    if [ -r "$_LOAD_ENV_CFG/.env" ]; then
        _load_env_lookup "$_LOAD_ENV_CFG/.env" "$key" "$_LOAD_ENV_FILTER"
        out="$_LOAD_ENV_FOUND"
        _LOAD_ENV_FOUND=""
    fi
    [ -n "$out" ] || out="$def"
    printf '%s' "$out"
}

# A later line overrides a key this loader set; a non-empty pre-existing export always wins.
_load_env_file() {
    local envfile i=0 k v name own=" " exported=" "
    _load_env_resolve
    envfile="$_LOAD_ENV_CFG/.env"
    [ -r "$envfile" ] || return 0
    ENV_OS_FILTER="$_LOAD_ENV_FILTER"
    _load_env_records "$envfile" "$ENV_OS_FILTER"
    while IFS= read -r name; do exported="$exported$name "; done < <(compgen -e)
    while [ "$i" -lt "${#_LOAD_ENV_KEYS[@]}" ]; do
        k="${_LOAD_ENV_KEYS[$i]}"
        v="${_LOAD_ENV_VALS[$i]}"
        i=$((i + 1))
        case "$own" in
            *" $k "*) export "$k=$v"; continue ;;
        esac
        case "$exported" in
            *" $k "*) if [ -n "${!k:-}" ]; then continue; fi ;;
        esac
        export "$k=$v"
        own="$own$k "
    done
    _LOAD_ENV_KEYS=()
    _LOAD_ENV_VALS=()
    return 0
}
