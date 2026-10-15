#!/bin/bash
# EXPERIMENTAL (#2585): runs one test in a light jail; usage and limits: experimental/test-jail/README.md
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

JAIL_TREE="$SCRIPT_CHECKOUT_ROOT"
pin_mode=full
secs=180
probe=0
allow_weaker=0
trace_rel=""
trace_out=""
test_rel=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tree)    JAIL_TREE="${2:?--tree needs a directory}"; shift 2 ;;
        --pin)     pin_mode="${2:?--pin needs a mode}"; shift 2 ;;
        --timeout) secs="${2:?--timeout needs seconds}"; shift 2 ;;
        --trace)   trace_rel="${2:?--trace needs a decoy path}"; trace_out="${3:?--trace needs an output file}"; shift 3 ;;
        --probe)   probe=1; shift ;;
        --allow-weaker-pin) allow_weaker=1; shift ;;
        -*)        echo "run-jailed: unknown option: $1" >&2; exit 2 ;;
        *)         test_rel="$1"; shift ;;
    esac
done
case "$pin_mode" in
    none|state|full) ;;
    *) echo "run-jailed: --pin must be none, state or full: $pin_mode" >&2; exit 2 ;;
esac
if [[ -n "$trace_out" && "$trace_out" != /* && "$trace_out" != [A-Za-z]:* ]]; then
    trace_out="$PWD/$trace_out"
fi

iso="$(mktemp -d)" || { echo "SAFE-RUN: mktemp failed" >&2; exit 96; }
[[ -n "$iso" && -d "$iso" ]] || { echo "SAFE-RUN: no temp dir" >&2; exit 96; }
readonly iso
trap 'rm -rf "$iso"' EXIT
mkdir -p "$iso/home" "$iso/gh-config" "$iso/glab-config" "$iso/deny-bin" "$iso/pin"

# Loud deny stubs: reached only when a test's own stub did not resolve.
for tool in gh glab; do
    printf '#!/bin/bash\necho "SAFE-RUN: real %s blocked (args: $*)" >&2\nexit 97\n' "$tool" > "$iso/deny-bin/$tool"
    chmod +x "$iso/deny-bin/$tool"
done
# Agent CLIs live in a shared dir that cannot be dropped: shadow them, bash and cmd forms.
for tool in codex claude; do
    printf '#!/bin/bash\necho "SAFE-RUN: real %s blocked (args: $*)" >&2\nexit 97\n' "$tool" > "$iso/deny-bin/$tool"
    printf '@echo SAFE-RUN: real %s blocked 1>&2\r\n@exit /b 97\r\n' "$tool" > "$iso/deny-bin/$tool.cmd"
    chmod +x "$iso/deny-bin/$tool" "$iso/deny-bin/$tool.cmd"
done

new_path=""
dropped=""
IFS=':' read -r -a entries <<< "$PATH"
for d in "${entries[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d/gh" || -e "$d/gh.exe" || -e "$d/glab" || -e "$d/glab.exe" ]]; then
        # A shared system dir cannot be dropped without losing unrelated tools.
        if [[ -e "$d/bash" || -e "$d/bash.exe" || -e "$d/git.exe" || -e "$d/node.exe" ]]; then
            echo "SAFE-RUN: forge binary lives in a shared dir, cannot isolate: $d" >&2
            exit 96
        fi
        dropped="$dropped $d"
        continue
    fi
    new_path="${new_path:+$new_path:}$d"
done
export PATH="$iso/deny-bin:$new_path"

# Retired root names are unset so no test reads a stale one. The list comes from this tool's
# own checkout, never from --tree: an old export may not carry the builder.
retired_fail() { echo "SAFE-RUN: cannot read the retired env names: $1" >&2; exit 96; }
builder="$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js"
[[ -f "$builder" ]] || retired_fail "no $builder"
if command -v cygpath >/dev/null 2>&1; then builder="$(cygpath -m "$builder")"; fi
retired_list="$(node "$builder" --print-retired-env-names 2>/dev/null)" || retired_fail "the builder failed"
retired_names=""
retired_count=0
valid_name='^[A-Za-z_][A-Za-z0-9_]*$'
while IFS= read -r retired; do
    retired="${retired%$'\r'}"
    [[ -z "$retired" ]] && continue
    [[ "$retired" =~ $valid_name ]] || retired_fail "not a variable name: $retired"
    unset "$retired"
    retired_names="${retired_names:+$retired_names }$retired"
    retired_count=$((retired_count + 1))
done <<< "$retired_list"
[[ "$retired_count" -gt 0 ]] || retired_fail "the builder printed no name"

if command -v cygpath >/dev/null 2>&1; then
    home_native="$(cygpath -m "$iso/home")"
else
    home_native="$iso/home"
fi
export HOME="$home_native" USERPROFILE="$home_native"
export GH_CONFIG_DIR="$iso/gh-config" GLAB_CONFIG_DIR="$iso/glab-config"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITLAB_TOKEN GLAB_TOKEN CLAUDE_CODE_SESSION_ID
unset RUN_ALL_CACHE_DIR ROOT_DECOY_DIR ROOT_DECOY_REAL_AGENTS_MAIN_ROOT
unset SSH_AUTH_SOCK SSH_AGENT_PID ANTHROPIC_API_KEY OPENAI_API_KEY
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=echo GIT_SSH_COMMAND=false
# An empty value resets the credential-helper list inherited from system config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

# Fail closed: after isolation, forge and agent CLIs must resolve to the deny stubs.
for tool in gh glab codex claude; do
    resolved="$(command -v "$tool" || true)"
    if [[ "$resolved" != "$iso/deny-bin/$tool" ]]; then
        echo "SAFE-RUN: $tool resolves to '$resolved', not the deny stub" >&2
        exit 96
    fi
done
if command -v where.exe >/dev/null 2>&1; then
    for exe in gh.exe glab.exe; do
        if where.exe "$exe" >/dev/null 2>&1; then
            echo "SAFE-RUN: $exe still reachable for a native spawn" >&2
            exit 96
        fi
    done
fi

if [[ "$probe" -eq 1 ]]; then
    echo "dropped:$dropped"
    echo "gh=$(command -v gh) glab=$(command -v glab)"
    echo "HOME=$HOME USERPROFILE=$USERPROFILE"
    echo "bash=$(command -v bash) node=$(command -v node) git=$(command -v git)"
    echo "retired-env-unset: $retired_count"
    exit 0
fi

[[ -n "$test_rel" ]] || { echo "run-jailed: test path required" >&2; exit 2; }
# Only a plain tree-relative path: any other spelling could slip past the list below.
not_plain='^(/|[A-Za-z]:|\./)|\.\.|//|\\'
if [[ "$test_rel" =~ $not_plain ]]; then
    echo "SAFE-RUN: test path must be a plain relative path: $test_rel" >&2
    exit 95
fi
if [[ "$trace_rel" =~ $not_plain ]]; then
    echo "SAFE-RUN: --trace path must stay inside the decoy: $trace_rel" >&2
    exit 95
fi
# Tests that reach outside the jail by design (installer, real main checkout, mutation).
case "$test_rel" in
    tests/install/*|tests/agents/feature-agents-repo-split.sh|tests/run-all.sh|tests/mutation/*|\
    tests/bin/main-session-sync.sh|tests/bin/main-session-sync-toggle.sh|tests/bin/TL3-*|\
    tests/bin/feature-refactor-prompts-extract.sh)
        echo "SAFE-RUN: forbidden test: $test_rel" >&2
        exit 95 ;;
esac
cd "$JAIL_TREE" || exit 2

# Build caches land under the host temp area (tests/lib/test-cache-base.js), never HOME. A tree
# whose launcher lacks the pin function asked for stops here (rc 94); only --allow-weaker-pin
# lets it run under the strongest pin it does have.
pin_unmet() {
    echo "SAFE-RUN: pin unmet: requested=$pin_mode, the tree's launcher has no $1 (pass --allow-weaker-pin to run under a weaker pin)" >&2
    exit 94
}
obtained="$pin_mode"
detail=""
if [[ "$pin_mode" != none ]]; then
    export FEATURE_644_PHASE="${FEATURE_644_PHASE:-0}"
    # shellcheck disable=SC1091
    . bin/lib/run-all-launch.sh
    if [[ "$obtained" == full ]] && ! declare -F run_all_pin_test_env >/dev/null 2>&1; then
        [[ "$allow_weaker" -eq 1 ]] || pin_unmet run_all_pin_test_env
        obtained=state
    fi
    if [[ "$obtained" == state ]] && ! declare -F run_all_pin_state_dirs >/dev/null 2>&1; then
        [[ "$allow_weaker" -eq 1 ]] || pin_unmet run_all_pin_state_dirs
        obtained=none
    fi
    case "$obtained" in
        full)
            run_all_pin_test_env "$iso/pin" || { echo "SAFE-RUN: cannot pin the per-run test environment" >&2; exit 94; }
            detail="decoy+state AGENTS_MAIN_ROOT=$AGENTS_MAIN_ROOT" ;;
        state)
            run_all_pin_state_dirs "$iso/pin" || { echo "SAFE-RUN: cannot pin the per-run state directories" >&2; exit 94; }
            detail="state only" ;;
        none)
            detail="launcher has no pin function" ;;
    esac
fi
echo "PINNED: obtained=$obtained requested=$pin_mode${detail:+ $detail}"

if [[ -n "$trace_rel" ]]; then
    [[ -n "${ROOT_DECOY_DIR:-}" ]] || { echo "run-jailed: --trace needs the root decoy (--pin full)" >&2; exit 93; }
    cp "$SCRIPT_CHECKOUT_ROOT/experimental/test-jail/trace-stub.js" "$ROOT_DECOY_DIR/$trace_rel" || exit 93
    export TRACE_STUB_NAMES="$retired_names"
    export TRACE_STUB_OUT="$trace_out"
    : > "$TRACE_STUB_OUT"
fi

bash bin/run-with-timeout.sh "$secs" bash "$test_rel"
rc=$?
report=""
if declare -F run_all_hit_report >/dev/null 2>&1; then report=run_all_hit_report
elif declare -F run_all_root_decoy_report >/dev/null 2>&1; then report=run_all_root_decoy_report
fi
if [[ -n "$report" ]]; then
    if ! "$report"; then
        echo "PINNED: root decoy, command guard or worktree change hit (tests/run-all.sh would count one FAIL)"
        [[ "$rc" -eq 0 ]] && rc=92
    fi
fi
exit "$rc"
