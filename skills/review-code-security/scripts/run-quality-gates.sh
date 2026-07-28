#!/usr/bin/env bash
# Run code-quality lint gates alongside the security review.
# Advisory only — non-zero exit per gate is a warning, not a blocker.
set -uo pipefail

GATES_TOTAL=0
GATES_RAN=0
GATES_MISSING=0
GATES_MISSING_NAMES=""
MERGE_BASE=""
MERGE_BASE_FALLBACK=no

# Every full path below is built from $AGENTS_CONFIG_DIR, so a value the script cannot
# build a trustworthy path from is not a gate problem — it is a configuration problem, and
# it has to say so on STDOUT. Under `set -u` an unset variable killed the first gate line
# with an empty stdout and exit 1, which the SKILL's advisory contract ("non-zero is a
# warning") reads as a run worth shrugging at. A RELATIVE value is rejected rather than
# resolved: this runner is invoked with the CWD set to the tree UNDER REVIEW, so a relative
# path would execute scripts supplied by whatever is being reviewed.
_unusable_config_reason() {
    local dir="${AGENTS_CONFIG_DIR:-}"
    if [[ -z "$dir" ]]; then
        echo "AGENTS_CONFIG_DIR is unset or empty"
        return 0
    fi
    # Absolute in either dialect: POSIX, and the drive-letter form Git Bash and pwsh hand over.
    case "$dir" in
        /*|[A-Za-z]:[/\\]*) ;;
        *) echo "AGENTS_CONFIG_DIR is not an absolute path (would resolve inside the reviewed tree): $dir"; return 0 ;;
    esac
    if [[ ! -d "$dir" ]]; then
        echo "AGENTS_CONFIG_DIR is not a directory: $dir"
        return 0
    fi
    return 0
}

# The base every gate is scoped by. HEAD~1 is a degradation, not an error — a detached
# checkout, a shallow clone, or a default branch that is not `main` all reach it — and the
# run continues. But it used to be announced on STDERR alone, where nothing downstream
# looks, so every gate examined the wrong range and the costliest one self-reported an
# empty diff, which reads as a clean pass. The value is set rather than echoed because the
# caveat and the base are two facts and a command substitution can only carry one.
_resolve_merge_base() {
    MERGE_BASE=""
    if git fetch origin main --no-tags 2>/dev/null; then
        MERGE_BASE=$(git merge-base origin/main HEAD 2>/dev/null || true)
    fi
    if [[ -z "$MERGE_BASE" ]]; then
        MERGE_BASE=$(git merge-base main HEAD 2>/dev/null || true)
    fi
    if [[ -z "$MERGE_BASE" ]]; then
        MERGE_BASE=HEAD~1
        MERGE_BASE_FALLBACK=yes
    fi
}

# Every gate is named by its full path under the agents config dir, never by bare name:
# a bare name resolves only if a PATH shim was installed, and `|| true` cannot tell exit 127
# (command not found) from a gate's own advisory non-zero exit. A gate with no shim was
# therefore skipped silently and forever while the report still read as a full sweep.
# An absent executable now becomes a line in the report, in the same `## <name>: <verdict>`
# family the gates themselves print, so a reviewer sees the hole instead of inferring a pass.
# A gate that ran and complained stays advisory — that distinction is the point.
#
# Three states, three verdicts, because they are three different facts and only one of them
# is absence. `-x` alone conflated them: the Windows shim the installer writes never
# depended on the execute bit, and `core.fileMode=false`, a copied tree, and several mounts
# all produce a gate that exists and runs perfectly with `-x` false. Every gate carries a
# bash shebang, so interpreting one directly preserves its behaviour exactly. A gate that
# cannot be READ can run under no invocation form at all, and is neither called absent
# (which sends the reader hunting for an install when the repair is a chmod) nor counted
# among the gates that ran.
_run_gate() { # <full-path> [args...]
    local exe="$1" name
    shift
    name=$(basename "$exe")
    GATES_TOTAL=$((GATES_TOTAL + 1))
    if [[ ! -e "$exe" ]]; then
        echo "## $name: NOT FOUND — no file at $exe"
        GATES_MISSING=$((GATES_MISSING + 1))
        GATES_MISSING_NAMES="${GATES_MISSING_NAMES:+$GATES_MISSING_NAMES, }$name"
        return 0
    fi
    if [[ ! -r "$exe" ]]; then
        echo "## $name: UNREADABLE — present but not readable at $exe (chmod +r to include it)"
        return 0
    fi
    GATES_RAN=$((GATES_RAN + 1))
    if [[ -x "$exe" ]]; then
        "$exe" "$@" || true
    else
        bash "$exe" "$@" || true
    fi
}

CONFIG_REASON=$(_unusable_config_reason)
if [[ -n "$CONFIG_REASON" ]]; then
    echo "## gates: NOT RUN — $CONFIG_REASON"
    exit 0
fi

_resolve_merge_base
if [[ "$MERGE_BASE_FALLBACK" = yes ]]; then
    echo "## merge-base: FALLBACK — no merge-base against main; every gate is scoped to HEAD~1"
fi

_run_gate "${AGENTS_CONFIG_DIR}/bin/review-code-codex" --base "$MERGE_BASE" --context "${AGENTS_CONFIG_DIR}/rules/core-principles.md"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-prompt-size" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/check-inline-procedures" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-code-size" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-env-example" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-step-numbers" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-e2e-coverage" --base "$MERGE_BASE"
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-bare-python" --base "$MERGE_BASE"

# The last line, and printed even when nothing is missing: a total that appears only when
# something is wrong cannot be relied on to be there, and one NOT FOUND line among eight
# blocks of gate output is exactly what a reader skims past.
if [[ "$GATES_MISSING" -gt 0 ]]; then
    echo "## gates: $GATES_RAN/$GATES_TOTAL ran, $GATES_MISSING NOT FOUND ($GATES_MISSING_NAMES)"
else
    echo "## gates: $GATES_RAN/$GATES_TOTAL ran, 0 NOT FOUND"
fi

exit 0
