# tests/bin/feature-2478-fallback/helpers.sh — CC-fallback helpers for tests/bin/feature-2478-*.sh
# (sourced after tests/bin/feature-2937-review-loop/fixture.sh, never run on its own).
# Tests: tests/bin/feature-2478-fallback/helpers.sh
# Tags: feature-2478, test-infrastructure, codex-review-loop, cc-fallback, scope:issue-specific
#
# A fallback round is a prestaged ADVANCE of the real loop: the reviewer agent's report is the
# input, and the per-format producer / stage name / verdict keyword below are its contract.

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${FX_TMP:-}" ]; then
    echo "helpers.sh is sourced by tests/bin/feature-2478-*.sh after the 2937 fixture; nothing to run on its own"
    exit 0
fi

# producer_of <fmt> / stage_of <fmt> / verdict_of <fmt> — the per-format fallback contract.
producer_of() {
    case "$1" in
        test-review) printf 'test-reviewer' ;;
        security-plan) printf 'plan-security-reviewer' ;;
        outline-plan) printf 'outline-reviewer' ;;
        detail-plan) printf 'detail-reviewer' ;;
    esac
}
stage_of() {
    case "$1" in
        outline-plan) printf 'outline' ;;
        detail-plan) printf 'detail' ;;
        *) printf '%s' "$1" ;;
    esac
}
verdict_of() {
    if [ "$1" = outline-plan ]; then printf 'MISSING_ALTERNATIVE: a third approach was not considered'
    else printf 'NEEDS_REVISION'; fi
}
# raw_of <sid> <fmt> — where the loop keeps the fallback raw of that stage.
raw_of() { printf '%s/%s-%s-fallback-raw.md' "$P" "$1" "$(stage_of "$2")"; }
round_file() { clf_round_path _ "$1" "$2"; }
ledger_of() { clf_ledger_path _ "$1" "$2"; }
artifact_of() { clf_artifact_path _ "$1" "$2"; }

# report <file> <line...> — a fallback reviewer report in the codex-output contract.
report() {
    local f="$1"
    shift
    {
        printf 'Preamble outside the block is ignored.\n\n'
        printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
        printf '%s\n' "$@"
        printf '<!-- end-codex-output -->\n'
    } > "$f"
}

# fb <sid> <fmt> <report> [args...] — one prestaged ADVANCE of the real loop (sets L_*).
fb() {
    local sid="$1" fmt="$2" rep="$3"
    shift 3
    loop "$sid" "$fmt" --prestaged-report "$rep" --prestaged-producer "$(producer_of "$fmt")" \
        --prestaged-exec PERFORMED "$@"
}

# brief <sid> <fmt> [args...] — the loop's --fallback-brief (sets L_*).
brief() {
    local sid="$1" fmt="$2"
    shift 2
    loop "$sid" "$fmt" --fallback-brief "$@"
}

# wrapa <skill> <sid> [args...] — the real stage wrapper with forwarded arguments (sets W_*).
wrapa() {
    local skill="$1" sid="$2" errf="$FX_TMP/wrapa.err"
    shift 2
    W_RC=0
    W_OUT="$( cd "$REPO" || exit 1
        export AGENTS_MAIN_ROOT="$ROOT"
        SESSION_ID="$sid" PLANS_DIR="$P" EXTENSIONS_USED="${WRAP_EXT:-0}" \
            bash "$ROOT/skills/$skill/scripts/run-codex-review-loop.sh" "$@" 2>"$errf"
    )" || W_RC=$?
    W_ERR="$(cat "$errf" 2>/dev/null)"
}

# ledger_rows <sid> <fmt> — the C<N>| rows of the ledger, one per line ('' when absent).
ledger_rows() { local l; l="$(ledger_of "$1" "$2")"; [ -f "$l" ] && grep -E '^C[0-9]+\|' "$l" | tr -d '\r'; }
