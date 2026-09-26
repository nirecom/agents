# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, real-git, harness, TL2, scope:common
#
# The slice of tests/bin-check-on-demand-rules.sh's preamble that fixtures.sh actually
# reads — BASE, TOKEN, MARKER, CASE_N, node_path — so a scenario script can source the
# real fixtures.sh and RUN it instead of scanning its text. Never sourced by the
# dispatcher: each scenario gets its own child bash, so a scenario's PATH shim, its
# broken template and its temp tree all die with that child and cannot reach the next one.

BASE="${FX_BASE:?FX_BASE must name the private temp root for this scenario}"
mkdir -p "$BASE"

TOKEN='.on-demand-only/never-match'
MARKER='<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->'
CASE_N=0

NODE_PATH_HAS_CYGPATH=0
command -v cygpath >/dev/null 2>&1 && NODE_PATH_HAS_CYGPATH=1
declare -A NODE_PATH_CACHE=()
node_path() {
    local key="$1"
    if [ -z "${NODE_PATH_CACHE["$key"]+x}" ]; then
        if [ "$NODE_PATH_HAS_CYGPATH" -eq 1 ]; then
            NODE_PATH_CACHE["$key"]="$(cygpath -m "$key")"
        else
            NODE_PATH_CACHE["$key"]="$key"
        fi
    fi
    printf '%s\n' "${NODE_PATH_CACHE["$key"]}"
}

# shellcheck source=../bin-check-on-demand-rules/fixtures.sh
. "${FIXTURES:?FIXTURES must point at tests/bin-check-on-demand-rules/fixtures.sh}"
