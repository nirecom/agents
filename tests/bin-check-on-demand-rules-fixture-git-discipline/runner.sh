# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, real-git, runner, TL2, scope:common
#
# The execution primitive the E and F blocks share: run one scenario script against the
# REAL fixtures.sh in a child bash and read its `key=value` report back. Kept apart from
# scanners.sh because that file's whole subject is text — this one's is behaviour, and the
# two must not borrow each other's failure modes. Sourced before either block; emits no
# PASS lines.

export FIXTURES
export CHECKER="$AGENTS_ROOT/bin/check-on-demand-rules.sh"
export FX_HARNESS="$CASE_DIR/fx-harness.sh"
SCEN_DIR="$WORK/scenarios"
mkdir -p "$SCEN_DIR"

# fx_scenario <name> — runs $SCEN_DIR/<name>.sh with a private FX_BASE and prints its
# combined output. The timeout is the suite's own wrapper: a scenario that plants a
# failing `git` on PATH can otherwise wedge a real git subprocess with no verdict.
fx_scenario() {
    local n="$1"
    export FX_BASE="$WORK/fxbase-$n"
    mkdir -p "$FX_BASE"
    bash "$TIMEOUT" 300 bash "$SCEN_DIR/$n.sh" 2>&1
}

# fx_get <report> <key> — the value of one `key=value` line, empty when absent. Values may
# contain `=` (a Windows path does), so only the first one splits.
fx_get() {
    printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-
}

# fx_missing <report> <key>… — prints the first key the scenario never reported, exit 0.
# A scenario that died mid-way reports none of them, and a case that only compares VALUES
# would read every comparison as "not what we wanted" and grade the crash as a finding.
fx_missing() {
    local report="$1" k
    shift
    for k in "$@"; do
        if ! printf '%s\n' "$report" | grep -qE "^$k="; then printf '%s' "$k"; return 0; fi
    done
    return 1
}

# A repo whose hooks are disabled names the platform's null device. On Git Bash the
# MSYS argument conversion rewrites `/dev/null` to `nul` on its way into git.exe, so the
# stored string is host-dependent while the guarantee is not (CPR-UNV: name the
# environment-specific assumption instead of hard-coding one host's spelling).
is_null_device() {
    case "$1" in
        /dev/null | nul | NUL | Nul) return 0 ;;
        *) return 1 ;;
    esac
}
