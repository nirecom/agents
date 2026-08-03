#!/bin/bash
# hooks/lib/load-env.sh
#
# Bash-side .env loader shared by git hooks. Mirrors hooks/lib/load-env.js.
#
# Source-only; defines exactly one function so a test can exercise it without
# also executing an entrypoint's side effects.
#
#   . "$(dirname "$0")/lib/load-env.sh"
#   _load_env_file
#
# Config dir resolution: $AGENTS_CONFIG_DIR, else $_cfg_dir when the sourcing
# entrypoint already resolved one, else this file's grandparent directory.
# Existing environment values always win over .env.

_load_env_cfg_dir() {
    if [ -n "${AGENTS_CONFIG_DIR:-}" ]; then
        printf '%s' "$AGENTS_CONFIG_DIR"
    elif [ -n "${_cfg_dir:-}" ]; then
        printf '%s' "$_cfg_dir"
    else
        (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
    fi
}

_load_env_file() {
    local cfgdir
    cfgdir="$(_load_env_cfg_dir)"
    local envfile="$cfgdir/.env"
    [ -r "$envfile" ] || return 0
    # The .env belongs to the config dir; the filter binary belongs to the
    # installed agents repo. Prefer the config dir's copy, fall back to this
    # file's own repo so an alternate config dir still gets OS filtering.
    ENV_OS_FILTER="$cfgdir/bin/env-os-filter"
    if [ ! -x "$ENV_OS_FILTER" ]; then
        ENV_OS_FILTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/env-os-filter"
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
                # Strip optional surrounding quotes
                case "$val" in
                    \"*\") val="${val#\"}"; val="${val%\"}" ;;
                    \'*\') val="${val#\'}"; val="${val%\'}" ;;
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
