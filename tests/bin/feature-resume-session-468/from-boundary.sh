# shellcheck shell=bash
# tests/bin/feature-resume-session-468/from-boundary.sh — T24-T25: --from on unknown ids and on ids built to escape the plans dir. Sourced by tests/bin/feature-resume-session-468.sh; not standalone.
# Tests: bin/resume-session-detect
# Tags: session, resume, input-validation, path-traversal, security, scope:common, pwsh-not-required, TL2

if ! declare -F run_cli >/dev/null 2>&1; then
    echo "from-boundary.sh: sourced fragment — run tests/bin/feature-resume-session-468.sh instead" >&2
    return 1 2>/dev/null || exit 1
fi

echo ""
echo "=== T24/T25: --from on ids that resolve to nothing, and on ids built to escape the plans dir ==="

# T19/T20 cover the unknown FLAG; nothing covers an unknown VALUE. The two are
# different contracts: a bad flag is a caller bug (exit 1, stderr), while a
# well-formed id that simply has no surviving state is the routine miss the
# SKILL dispatches on — it must stay a structured record on stdout with the
# documented exit 3, so the procedure can say "nothing survives" instead of
# treating it as a crash.
t24_root_of() {
    printf '%s/%s' "$TMPDIR_BASE" "$1"
}

# Runs the real CLI with an arbitrary raw --from argument against a fixture
# store, so the argument itself is the only variable under test.
run_from_arg() {
    local root="$1" sid_arg="$2"
    mkdir -p "$root/state" "$root/plans" "$root/transcripts"
    ( cd "$SCRIPT_CHECKOUT_ROOT" && WORKFLOW_STATE_DIR="$root/state" \
        WORKFLOW_PLANS_DIR="$root/plans" CLAUDE_TRANSCRIPT_BASE_DIR="$root/transcripts" \
        run_with_timeout node "$CLI" --from "$sid_arg" >"$root/stdout" 2>"$root/stderr" ) \
        && LAST_EXIT=0 || LAST_EXIT=$?
    LAST_OUT=$(cat "$root/stdout" 2>/dev/null || true)
    LAST_ERR=$(cat "$root/stderr" 2>/dev/null || true)
}

T24_ROOT=$(t24_root_of t24)
run_from_arg "$T24_ROOT" "sess-t24-never-existed"
assert_type "T24a. a well-formed but unknown id still answers on the upstream record shape" "upstream"
assert_field "T24b. availability=none for an id with nothing left to resume" "availability" "none"
assert_field "T24c. reason=unknown-session names WHY nothing is available" "reason" "unknown-session"
assert_exit "T24d. exit 3 — the documented 'nothing survives for that id' code, not the exit 1 of a bad flag" "3"

# T25 — the --from value is attacker-influenced (it arrives from a donor list,
# a pasted id, or a delegating agent). Since #2302 `buildUpstreamView()` and
# `artifactsFor()` validate it against SESSION_ID_VALID_RE before any path is
# built, so a malformed id is refused as unknown-session without ever touching
# the filesystem. Three separate harms to keep out: the CLI must never execute
# it, never read a file's CONTENT from outside the plans dir, and never disclose
# an outside PATH into this conversation.
T25_ROOT=$(t24_root_of t25)
mkdir -p "$T25_ROOT/plans" "$T25_ROOT/state" "$T25_ROOT/transcripts"
# Sentinels planted OUTSIDE WORKFLOW_PLANS_DIR, at exactly the names a `../`
# escape would land on.
mkdir -p "$T25_ROOT/adjacent/plans"
printf 'T25-OUTSIDE-SECRET-BODY\n' > "$T25_ROOT/adjacent/escape-t25-intent.md"
printf 'T25-OUTSIDE-SECRET-BODY\n' > "$T25_ROOT/adjacent/escape-t25-outline.md"
printf 'T25-OUTSIDE-SECRET-BODY\n' > "$T25_ROOT/adjacent/escape-t25-detail.md"

T25_REJECTED=0
T25_PROBLEMS=""
for T25_ARG in '../../../etc/passwd' '..' '/' '\' 'a/b' 'a\b' ';id' '$(id)' 'x`id`' 'a|b' '&& id'; do
    T25_CASE="$T25_ROOT/case-$T25_REJECTED"
    run_from_arg "$T25_CASE" "$T25_ARG"
    if [ "$LAST_EXIT" != "3" ]; then
        T25_PROBLEMS="$T25_PROBLEMS [<$T25_ARG> exited $LAST_EXIT, not 3]"
    fi
    printf '%s' "$LAST_OUT" | grep -qF '"availability":"none"' ||
        T25_PROBLEMS="$T25_PROBLEMS [<$T25_ARG> was not answered with availability=none]"
    printf '%s' "$LAST_OUT" | grep -qF '"reason":"unknown-session"' ||
        T25_PROBLEMS="$T25_PROBLEMS [<$T25_ARG> was not rejected as unknown-session]"
    # A metacharacter that reached a shell would print id(1) output or a shell
    # diagnostic; neither may appear on either stream.
    case "$LAST_OUT$LAST_ERR" in
        *uid=*|*'command not found'*|*'not recognized'*)
            T25_PROBLEMS="$T25_PROBLEMS [<$T25_ARG> reached a shell]" ;;
    esac
    T25_REJECTED=$((T25_REJECTED + 1))
done

# Each of these fails SESSION_ID_VALID_RE, so the refusal is the validation
# itself (#2302) — not the accident that no file happens to exist at the
# joined path.
if [ -z "$T25_PROBLEMS" ]; then
    pass "T25a. all $T25_REJECTED separator/traversal/metacharacter ids are refused by sid validation as unknown-session with exit 3, and none reaches a shell"
else
    fail "T25a. a boundary --from value was mishandled;$T25_PROBLEMS"
fi

# T25b — the one shape that would resolve a path outside the plans dir if the
# id were joined unvalidated: `../<name>` with artifacts planted next to the
# plans dir. Since #2302 the id fails SESSION_ID_VALID_RE, so it must be
# refused exactly like any other unknown id — exit 3, availability=none,
# reason=unknown-session — and nothing outside may be DISCLOSED: no sentinel
# body, no planted artifact filename, no outside absolute path, and no state
# adoption attempted.
run_from_arg "$T25_ROOT/adjacent" "../escape-t25"
T25B_PROBLEMS=""
# Fixture anchor: the planted files must exist, or the absence checks below
# would hold for the boring reason that there was nothing to find.
[ -f "$T25_ROOT/adjacent/escape-t25-intent.md" ] ||
    T25B_PROBLEMS="$T25B_PROBLEMS [fixture never planted the outside artifact]"
[ "$LAST_EXIT" = "3" ] ||
    T25B_PROBLEMS="$T25B_PROBLEMS [exited $LAST_EXIT, not 3]"
printf '%s' "$LAST_OUT" | grep -qF '"availability":"none"' ||
    T25B_PROBLEMS="$T25B_PROBLEMS [not answered with availability=none]"
printf '%s' "$LAST_OUT" | grep -qF '"reason":"unknown-session"' ||
    T25B_PROBLEMS="$T25B_PROBLEMS [not rejected as unknown-session]"
case "$LAST_OUT$LAST_ERR" in
    *T25-OUTSIDE-SECRET-BODY*)
        T25B_PROBLEMS="$T25B_PROBLEMS [the body of a file outside the plans dir was read into the output]" ;;
esac
for T25B_NAME in escape-t25-intent.md escape-t25-outline.md escape-t25-detail.md; do
    case "$LAST_OUT$LAST_ERR" in
        *"$T25B_NAME"*)
            T25B_PROBLEMS="$T25B_PROBLEMS [the outside artifact name $T25B_NAME was disclosed]" ;;
    esac
done
# The outside absolute path, in every spelling the CLI could emit it: the
# shell's own, the forward-slash Windows form, and the JSON-escaped backslash form.
T25B_ADJ_FORMS="$T25_ROOT/adjacent/escape-t25"
if command -v cygpath >/dev/null 2>&1; then
    T25B_ADJ_M="$(cygpath -m "$T25_ROOT/adjacent")/escape-t25"
    T25B_ADJ_W="$(cygpath -w "$T25_ROOT/adjacent")\\escape-t25"
    T25B_ADJ_FORMS="$T25B_ADJ_FORMS
$T25B_ADJ_M
${T25B_ADJ_W//\\/\\\\}"
fi
while IFS= read -r T25B_FORM; do
    [ -n "$T25B_FORM" ] || continue
    case "$LAST_OUT$LAST_ERR" in
        *"$T25B_FORM"*)
            T25B_PROBLEMS="$T25B_PROBLEMS [the outside absolute path <$T25B_FORM> was disclosed]" ;;
    esac
done <<< "$T25B_ADJ_FORMS"
printf '%s' "$LAST_OUT" | grep -qF '"attempted":true' &&
    T25B_PROBLEMS="$T25B_PROBLEMS [state adoption was attempted for a donor conjured from outside the plans dir]"
if [ -z "$T25B_PROBLEMS" ]; then
    pass "T25b. a ../ id planted against real files outside the plans dir is refused by sid validation (exit 3, unknown-session) and discloses no file content, artifact name or outside path"
else
    fail "T25b. the plans-dir boundary leaked;$T25B_PROBLEMS - raw: $LAST_OUT - stderr: $LAST_ERR"
fi
