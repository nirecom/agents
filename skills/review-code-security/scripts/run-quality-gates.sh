#!/usr/bin/env bash
# Run code-quality lint gates alongside the security review.
# Advisory only — non-zero exit per gate is a warning, not a blocker.
set -uo pipefail

GATES_TOTAL=0
GATES_RAN=0
GATES_MISSING=0
GATES_MISSING_NAMES=""
MERGE_BASE=""
MERGE_BASE_STATE=UNRESOLVED
MERGE_BASE_SOURCE=""
MERGE_BASE_DETAIL=""
MERGE_BASE_WARN=""
MERGE_BASE_ALT=""

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
        [A-Za-z]:[/\\]*|/*) ;;
        *) echo "AGENTS_CONFIG_DIR is not an absolute path (would resolve inside the reviewed tree): $dir"; return 0 ;;
    esac
    if [[ ! -d "$dir" ]]; then
        echo "AGENTS_CONFIG_DIR is not a directory: $dir"
        return 0
    fi
    return 0
}

# The base every gate is scoped by. Degradation is not an error — a detached checkout, a
# shallow clone, or a default branch that is not `main` all reach it — and the run continues.
# But it used to be announced on STDERR alone, where nothing downstream looks, so every gate
# examined the wrong range and the costliest one self-reported an empty diff, which reads as a
# clean pass. The values are set rather than echoed because the state and the base are
# separate facts and a command substitution can only carry one.

# The resolution CHAIN itself is no longer here: bin/resolve-merge-base.sh owns it (SSOT,
# #1638), because five callers each re-deriving the base is five different answers to the
# same question. This function only asks, and translates the answer into a base and a report.

# The helper being absent, unrunnable, or wrong about its own arguments is NOT rounded into
# FALLBACK: FALLBACK is a specific claim ("no merge-base against main, so HEAD~1"), and
# stating it when we simply could not ask would be a report that lies. Those cases are
# UNRESOLVED, which scopes to uncommitted changes against a base that certainly exists.
_resolve_merge_base() {
    local helper="${AGENTS_CONFIG_DIR}/bin/resolve-merge-base.sh"
    MERGE_BASE=""
    MERGE_BASE_STATE=UNRESOLVED
    MERGE_BASE_SOURCE=""
    MERGE_BASE_DETAIL=""
    MERGE_BASE_WARN=""
    MERGE_BASE_ALT=""

    if [[ ! -r "$helper" ]]; then
        # basename only — $helper is rooted at $AGENTS_CONFIG_DIR, an absolute host filesystem
        # path (e.g. C:\Users\<user>\...), and this detail string reaches operator-visible /
        # reviewable output.
        MERGE_BASE_DETAIL="the merge-base helper is not readable at bin/$(basename "$helper")"
        MERGE_BASE=HEAD
        return 0
    fi

    local out rc
    out=$(bash "$helper" -C . --format kv 2>/dev/null)
    rc=$?
    # Exit 3 is the helper REPORTING that nothing resolved — kv is still on stdout and is
    # worth parsing. Any other non-zero is the helper failing to answer at all.
    if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
        MERGE_BASE_DETAIL="the merge-base helper exited $rc without a usable answer"
        MERGE_BASE=HEAD
        return 0
    fi

    local k v base="" state="" src="" detail="" warn="" alt=""
    while IFS='=' read -r k v; do
        [[ "$v" == "-" ]] && v=""
        case "$k" in
            base)   base="$v" ;;
            state)  state="$v" ;;
            source) src="$v" ;;
            detail) detail="$v" ;;
            warn)   warn="$v" ;;
            alt_base) alt="$v" ;;
        esac
    done <<<"$out"

    MERGE_BASE_DETAIL="$detail"
    MERGE_BASE_WARN="$warn"
    MERGE_BASE_ALT="$alt"
    MERGE_BASE_SOURCE="$src"

    # An unrecognised state is treated as UNRESOLVED rather than trusted: a base this script
    # has no rule for is a base it cannot honestly scope eight gates by.
    case "$state" in
        RECORDED|RESOLVED)
            if [[ -z "$base" ]]; then
                MERGE_BASE_STATE=UNRESOLVED
                MERGE_BASE_DETAIL="${detail:-the helper reported $state with no base}"
                MERGE_BASE=HEAD
            else
                MERGE_BASE_STATE="$state"
                MERGE_BASE="$base"
            fi
            ;;
        SUSPECT)
            MERGE_BASE_STATE=SUSPECT
            MERGE_BASE=HEAD
            ;;
        FALLBACK)
            MERGE_BASE_STATE=FALLBACK
            MERGE_BASE=HEAD
            ;;
        UNRESOLVED)
            MERGE_BASE_STATE=UNRESOLVED
            MERGE_BASE=HEAD
            ;;
        *)
            MERGE_BASE_STATE=UNRESOLVED
            MERGE_BASE_DETAIL="the helper reported an unrecognised state: ${state:-<empty>}"
            MERGE_BASE=HEAD
            ;;
    esac
}

# Every gate is named by its full path under the agents config dir, never by bare name:
# a bare name resolves only if a PATH shim was installed, and `|| true` cannot tell exit 127
# (command not found) from a gate's own advisory non-zero exit. A gate with no shim was
# therefore skipped silently and forever while the report still read as a full sweep.
# An absent executable now becomes a line in the report, in the same `## <name>: <verdict>`
# family the gates themselves print, so a reviewer sees the hole instead of inferring a pass.
# A gate that ran and complained stays advisory — that distinction is the point.

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

# Five states, five reports, in the same `## <name>: <verdict>` family the gates print.
# RESOLVED prints NOTHING on purpose: a line that appears on every healthy run tells the
# reader nothing, and the existing contract fixes "no merge-base line when it resolved".
# The other four each carry information the reader cannot recover from the gate output alone.
_resolve_merge_base
case "$MERGE_BASE_STATE" in
    RESOLVED)
        ;;
    RECORDED)
        echo "## merge-base: RECORDED — $MERGE_BASE (${MERGE_BASE_SOURCE:-recorded-baseline})"
        ;;
    SUSPECT)
        echo "## merge-base: SUSPECT — ${MERGE_BASE_DETAIL:-the resolved merge-base is implausibly far from HEAD}; every gate is scoped to uncommitted changes (staged + unstaged) instead"
        ;;
    FALLBACK)
        echo "## merge-base: FALLBACK — no merge-base against main; every gate is scoped to uncommitted changes (staged + unstaged) instead"
        ;;
    *)
        echo "## merge-base: UNRESOLVED — ${MERGE_BASE_DETAIL:-no merge-base could be resolved}; every gate is scoped to uncommitted changes (staged + unstaged) instead"
        ;;
esac

# A separate line, never folded into the RECORDED one: "the base is the recorded one" and
# "the recorded one may be behind you" are two different facts, and a reader who only needs
# the second must not have to parse the first to find it (CPR-SC).
if [[ "$MERGE_BASE_WARN" == "post-session-head" ]]; then
    echo "## merge-base: NOTE — the recorded baseline was created after this session started; commits made before the branching sentinel are outside the reviewed range (alt base: ${MERGE_BASE_ALT:-unknown})"
fi

# --base-state goes to the codex reviewer ALONE. It is the only gate that emits a prose
# verdict a reader can mistake for a full-coverage judgement, so it is the only one that has
# to disclose an untrustworthy range. The other seven receive a resolved base and nothing more.
# The reviewer is reached through review-code-ledger, which forwards these arguments
# unchanged and additionally carries the round's concerns in and the round's delta out.
_run_gate "${AGENTS_CONFIG_DIR}/bin/review-code-ledger" --base "$MERGE_BASE" --base-state "$MERGE_BASE_STATE" --context "${AGENTS_CONFIG_DIR}/rules/core-principles.md"
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
