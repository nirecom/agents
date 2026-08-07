#!/usr/bin/env bash
# tests/feat-1763-severity-keyword-removal.sh
# Tests: bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, .github/labels.yml
# Tags: issue-create, severity, keyword-scan, label-policy, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real GitHub label application (needs a live token + network).
# - The SKILL.md label policy actually being applied by the model at runtime.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S1/S2: bin/ scripts must no longer infer severity. The keyword scan
# (grep -qwE 'abort|hang|security|leak') is deleted; severity is decided solely by
# the /issue-create label policy and arrives via --label.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IC="$AGENTS_DIR/bin/github-issues/issue-create.sh"
SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"
mkdir -p "$MOCKDIR"

# gh mock: capture --label args from `issue create`; everything else exits 1
# (non-fatal in issue-create.sh: auth-status warn / project resolver skip).
cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
    printf 'created\n' >> "${GH_CREATE_LOG:-/dev/null}"
    while [ $# -gt 0 ]; do
        if [ "$1" = "--label" ]; then printf '%s\n' "$2" >> "$GH_LABEL_CAPTURE"; fi
        shift
    done
    echo "https://github.com/test/repo/issues/999"
    exit 0
fi
exit 1
MOCK
chmod +x "$MOCKDIR/gh"

CAP="$WORK/labels.txt"
CREATED="$WORK/created.txt"

run_ic() {
    : > "$CAP"; : > "$CREATED"
    # Config pinning (rules/test.md): severity must be decided by the label policy
    # regardless of how the review/provenance switches happen to be set in the
    # developer's .env, so both are declared here rather than inherited.
    GH_LABEL_CAPTURE="$CAP" \
    GH_CREATE_LOG="$CREATED" \
    PATH="$MOCKDIR:$PATH" \
    AGENTS_CONFIG_DIR="" \
    ISSUE_VERDICT_REVIEW=off \
    ISSUE_PROVENANCE=off \
    ISSUE_CREATE_SKIP_SCHEMA=1 \
        bash "$IC" "$@" >/dev/null 2>"$WORK/stderr.txt"
    IC_RC=$?
    return $IC_RC
}
labels_seen() { tr '\n' ' ' < "$CAP"; }
severity_labels() { grep '^severity:' "$CAP" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'; }

# assert_created <name> → 0 when the run really did create an issue.
#
# Every "severity:high was NOT applied" assertion in this file is a negative, and a
# negative is satisfied for free by a run that never called `gh issue create`. A bad
# flag, a failed preflight, or a mock that exits non-zero would all yield an empty
# $CAP and a green result. Creation success is therefore asserted as a PRECONDITION
# before any absence is judged — the absence only carries meaning inside a real run.
assert_created() {
    local name="$1"
    if [ "${IC_RC:-1}" -ne 0 ]; then
        fail "$name" "PRECONDITION: issue-create.sh exited $IC_RC — severity absence proves nothing (stderr: $(head -n 1 "$WORK/stderr.txt" 2>/dev/null))"
        return 1
    fi
    local n; n=$(grep -c '^created$' "$CREATED" 2>/dev/null || printf '0')
    if [ "$n" != "1" ]; then
        fail "$name" "PRECONDITION: expected exactly 1 'gh issue create' invocation, saw $n — severity absence proves nothing"
        return 1
    fi
    return 0
}

echo "=== S1: keyword words no longer force severity:high (table-driven) ==="

while IFS='|' read -r name field word; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; field="${field//[[:space:]]/}"; word="${word//[[:space:]]/}"
    if [ "$field" = "title" ]; then
        run_ic --title "the $word case" --body "plain body"
    else
        run_ic --title "plain title" --body "the $word case"
    fi
    assert_created "$name" || continue
    if grep -qxF 'severity:high' "$CAP"; then
        fail "$name" "severity:high was forced by the keyword '$word' (labels: $(labels_seen))"
    else
        pass "$name"
    fi
done <<'TABLE'
K1-title-abort    | title | abort
K2-title-hang     | title | hang
K3-body-security  | body  | security
K4-body-leak      | body  | leak
K5-title-security | title | security
K6-body-abort     | body  | abort
TABLE

echo ""
echo "=== S1: --label passes through untouched ==="

# K7: explicit severity:low survives even alongside a former keyword.
run_ic --title "abort now" --body "b" --label "severity:low"
SEV="$(severity_labels)"
if [ "$SEV" = "severity:low" ]; then
    pass "K7-explicit-low-survives-keyword"
else
    fail "K7-explicit-low-survives-keyword" "want exactly 'severity:low' (got: '$SEV'; all labels: $(labels_seen))"
fi

# K8: no severity label given → no severity label emitted at all.
run_ic --title "abort hang security leak" --body "all four former keywords"
if assert_created "K8-no-severity-label-when-unspecified"; then
    SEV="$(severity_labels)"
    if [ -z "$SEV" ]; then
        pass "K8-no-severity-label-when-unspecified"
    else
        fail "K8-no-severity-label-when-unspecified" "unexpected severity label(s): '$SEV'"
    fi
fi

# K9: explicit severity:high is still honoured (CPR-ORTH counterpart of K1-K6).
run_ic --title "t" --body "b" --label "severity:high"
if grep -qxF 'severity:high' "$CAP"; then
    pass "K9-explicit-high-passes-through"
else
    fail "K9-explicit-high-passes-through" "explicit --label severity:high was dropped (labels: $(labels_seen))"
fi

# K10: type:task is still applied (regression guard — the edit must not break creation).
run_ic --title "t" --body "b"
if grep -qxF 'type:task' "$CAP"; then
    pass "K10-type-task-still-applied"
else
    fail "K10-type-task-still-applied" "issue creation broke (labels: $(labels_seen))"
fi

echo ""
echo "=== S1: --body-file is the same input, and must get the same treatment (CPR-ORTH) ==="
# --body and --body-file are symmetric ways to supply the body. A keyword scan that
# was deleted from the --body path but survived on the --body-file path (where the
# text is read with `cat` at a different point in the script) would be invisible to
# K1-K6 above. Real callers of /issue-create use --body-file for multi-line bodies,
# so this is the path that actually carries long, keyword-rich text.
bf() { local f="$WORK/body-$1.md"; shift; printf '%s\n' "$*" > "$f"; printf '%s' "$f"; }

while IFS='|' read -r name fname text; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; fname="${fname//[[:space:]]/}"
    text="${text#"${text%%[![:space:]]*}"}"
    run_ic --title "plain title" --body-file "$(bf "$fname" "$text")"
    assert_created "$name" || continue
    if grep -qxF 'severity:high' "$CAP"; then
        fail "$name" "severity:high was forced by --body-file content (labels: $(labels_seen))"
    else
        pass "$name"
    fi
done <<'TABLE'
K14-bodyfile-abort      | abort    | the abort case
K15-bodyfile-hang       | hang     | the process may hang here
K16-bodyfile-security   | security | a security concern was raised
K17-bodyfile-leak       | leak     | possible memory leak
K18-bodyfile-all-four   | all      | abort hang security leak
TABLE

# K19: a filename carrying special characters must not be word-split or re-globbed
# into a different file (or into no file at all) on the --body-file path.
SPECIAL="$WORK/a b (c) 'd'-security.md"
printf '%s\n' "abort hang security leak" > "$SPECIAL"
run_ic --title "plain title" --body-file "$SPECIAL"
if assert_created "K19-bodyfile-special-chars-in-path"; then
    SEV="$(severity_labels)"
    if [ -z "$SEV" ] && grep -qxF 'type:task' "$CAP"; then
        pass "K19-bodyfile-special-chars-in-path"
    else
        fail "K19-bodyfile-special-chars-in-path" "want creation with no severity label (severity: '$SEV'; all labels: $(labels_seen))"
    fi
fi

# K20: the explicit label still wins on the --body-file path (CPR-ORTH counterpart of K7).
run_ic --title "abort now" --body-file "$(bf explicit "abort hang security leak")" --label "severity:low"
SEV="$(severity_labels)"
if [ "$SEV" = "severity:low" ]; then
    pass "K20-bodyfile-explicit-low-survives"
else
    fail "K20-bodyfile-explicit-low-survives" "want exactly 'severity:low' (got: '$SEV'; all labels: $(labels_seen))"
fi

# K21: and explicit high is still honoured there too (CPR-ORTH counterpart of K9).
run_ic --title "t" --body-file "$(bf high "nothing notable")" --label "severity:high"
if grep -qxF 'severity:high' "$CAP"; then
    pass "K21-bodyfile-explicit-high-passes-through"
else
    fail "K21-bodyfile-explicit-high-passes-through" "explicit --label severity:high was dropped (labels: $(labels_seen))"
fi

echo ""
echo "=== S1/S2: source-level SSOT assertions ==="

if grep -qE "grep -qwE '?abort\|hang\|security\|leak" "$IC"; then
    fail "K11-keyword-scan-block-removed" "RED-EXPECTED: the keyword scan is still present in issue-create.sh"
else
    pass "K11-keyword-scan-block-removed"
fi

if grep -qF 'keyword scan matched' "$IC"; then
    fail "K12-keyword-scan-stderr-removed" "RED-EXPECTED: the 'keyword scan matched' stderr note is still present"
else
    pass "K12-keyword-scan-stderr-removed"
fi

if [ ! -f "$SKILL_MD" ]; then
    fail "K13-skill-declares-severity-ssot" "skills/issue-create/SKILL.md not found"
elif grep -qiE 'severity.*(SSOT|only definition|唯一の定義)|(SSOT|唯一の定義).*severity' "$SKILL_MD"; then
    pass "K13-skill-declares-severity-ssot"
else
    fail "K13-skill-declares-severity-ssot" "RED-EXPECTED: SKILL.md Label policy does not yet declare the severity SSOT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
