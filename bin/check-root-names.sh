#!/usr/bin/env bash
# Root-name gate (#2561): retired names, the classification table, structural rules,
# the script-root assignment form and the environment-variable rules.
# Usage: check-root-names.sh [--staged | --root <dir> | <file>...] [--repo agents|dotfiles]
#        [--only <check>] [--scope <prefix>] [--retired-names-from <file>]
# Exit 0 = clean, 1 = violation, 2 = usage error or unreadable input.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$SCRIPT_CHECKOUT_ROOT/bin/check-root-names/main.js" "$@"
