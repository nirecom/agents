#!/bin/bash
# hooks/lib/load-env.sh
#
# Bash-side .env loader shared by git hooks. Mirrors hooks/lib/load-env.js.
# Source-only; defines exactly one function so a test can exercise it without
# entrypoint side effects. Usage: `. "$(dirname "$0")/lib/load-env.sh"; _load_env_file`.
# Settings root: $AGENTS_MAIN_ROOT when set, else the checkout this file lives in.
# Existing environment values always win over .env.

_LOAD_ENV_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_load_env_cfg_dir() {
    if [ -n "${AGENTS_MAIN_ROOT:-}" ]; then
        printf '%s' "$AGENTS_MAIN_ROOT"
    else
        printf '%s' "$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT"
    fi
}

# _load_env_only_value <KEY[:-DEFAULT]> — print the value KEY carries in the
# settings root's .env, or DEFAULT when the file, the key, or its value is absent.
#
# Why a second reader instead of `_load_env_file` + "${KEY:-default}": the
# ambient process environment must NOT be able to answer. _load_env_file
# deliberately lets an explicit export win, which is right for settings but
# wrong for a value that decides whether a guard blocks — `VAR=off git commit`
# would otherwise be a one-word bypass. Mirrors readDefaultEnvFile() in
# hooks/lib/load-env.js, which exists for the same reason on the Node side.
_load_env_only_scan() {
    local envfile="$1" key="$2" filter="$3" line k v found=""
    _scan_body() {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|\#*) continue ;; esac
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                k="${BASH_REMATCH[1]}"
                [ "$k" = "$key" ] || continue
                v="${BASH_REMATCH[2]}"
                case "$v" in
                    \"*\") v="${v#\"}"; v="${v%\"}" ;;
                    \"*) continue ;;
                    \'*\') v="${v#\'}"; v="${v%\'}" ;;
                    \'*) continue ;;
                esac
                found="$v"
            fi
        done
    }
    # Process substitution, not a pipe: the loop must run in THIS shell or
    # $found never escapes the subshell.
    if [ -x "$filter" ]; then
        _scan_body < <("$filter" "$envfile")
    else
        _scan_body < "$envfile"
    fi
    printf '%s' "$found"
}

_load_env_only_value() {
    local spec="$1" key def cfgdir envfile filter out
    key="${spec%%:-*}"
    if [ "$key" = "$spec" ]; then def=""; else def="${spec#*:-}"; fi
    cfgdir="$(_load_env_cfg_dir)"
    envfile="$cfgdir/.env"
    out=""
    if [ -r "$envfile" ]; then
        filter="$cfgdir/bin/env-os-filter"
        if [ ! -x "$filter" ]; then
            filter="$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT/bin/env-os-filter"
        fi
        out="$(_load_env_only_scan "$envfile" "$key" "$filter")"
    fi
    [ -n "$out" ] || out="$def"
    printf '%s' "$out"
}

_load_env_file() {
    local cfgdir
    cfgdir="$(_load_env_cfg_dir)"
    local envfile="$cfgdir/.env"
    [ -r "$envfile" ] || return 0
    # The .env belongs to the settings root; the filter binary belongs to an
    # agents checkout. Prefer the settings root's copy, fall back to the checkout
    # this file lives in so a settings root without bin/ still gets OS filtering.
    ENV_OS_FILTER="$cfgdir/bin/env-os-filter"
    if [ ! -x "$ENV_OS_FILTER" ]; then
        ENV_OS_FILTER="$_LOAD_ENV_SCRIPT_CHECKOUT_ROOT/bin/env-os-filter"
    fi
    local line key val
    local _parse_body
    _parse_body() {
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip blank and comment lines
            case "$line" in ''|\#*) continue ;; esac
            # Match KEY=VAL (KEY: alphanumeric + underscore, must start with letter/underscore)
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                # Strip optional surrounding quotes. This loader has no multi-line
                # quote grammar (unlike hooks/lib/load-env.js#parseEnv) — an
                # opening quote unmatched on its own line is refused rather than
                # exported with a stray literal quote character.
                case "$val" in
                    \"*\") val="${val#\"}"; val="${val%\"}" ;;
                    \"*)
                        printf 'load-env.sh: %s discarded — unterminated quote\n' "$key" >&2
                        continue ;;
                    \'*\') val="${val#\'}"; val="${val%\'}" ;;
                    \'*)
                        printf 'load-env.sh: %s discarded — unterminated quote\n' "$key" >&2
                        continue ;;
                esac
                # Set only if not already in env (preserves explicit shell exports)
                if ! printenv "$key" >/dev/null 2>&1; then
                    export "$key"="$val"
                fi
            fi
        done
    }
    if [ -x "$ENV_OS_FILTER" ]; then
        _parse_body < <("$ENV_OS_FILTER" "$envfile")
    else
        _parse_body < "$envfile"
    fi
}
