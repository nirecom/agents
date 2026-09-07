#!/usr/bin/env bash
# Tests: rules/shell-commands.md, skills/_shared/resolve-plans-dir.md, skills/session-close/SKILL.md, skills/survey-code/SKILL.md, skills/worktree-end/SKILL.md, docs/ops.md, hooks/block-capture-echo/shape.js
# Tags: prompt-layer, capture-echo-guard, plans-dir, static-scan, scope:issue-specific, pwsh-not-required
# Serial: no

# Round 13, C7 — the prompt layer and the guard must agree. A document that tells the
# model to capture-then-display would be blocked at issue time (the #2170 deadlock), so
# every shell snippet in the changed docs is fed through detectCaptureEcho itself rather
# than through a hand-written pattern that could drift from the guard.
# PL-1 also sweeps every prompt file in the repo, so a NEW doc cannot reintroduce it.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_DIR
SCAN="$AGENTS_DIR/tests/feature-2170-prompt-layer/scan-docs.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

CHANGED_DOCS="
rules/shell-commands.md
skills/_shared/resolve-plans-dir.md
skills/session-close/SKILL.md
skills/survey-code/SKILL.md
skills/worktree-end/SKILL.md
docs/ops.md
"

abs_changed() {
    local rel
    for rel in $CHANGED_DOCS; do printf '%s\n' "$AGENTS_DIR/$rel"; done
}

# --- PL-0: every named document exists (guards against a silent rename) -----------
for rel in $CHANGED_DOCS; do
    [ -f "$AGENTS_DIR/$rel" ] && got=present || got=MISSING
    assert_eq "PL-0-doc-present-[$rel]" "present" "$got"
done

# --- PL-1: no shell snippet in the changed docs is capture-echo shaped ------------
hits="$(abs_changed | xargs node "$SCAN" hits)"
assert_eq "PL-1a-changed-docs-carry-no-capture-echo-snippet" "" "$hits"

# Non-vacuity: the scanner must actually have examined snippets, and must be able to
# report one — a doc set that yielded zero snippets would make PL-1a meaningless.
examined="$(abs_changed | xargs node "$SCAN" count)"
[ "${examined:-0}" -ge 3 ] && got=enough || got="only=$examined"
assert_eq "PL-1b-scanner-examined-real-snippets" "enough" "$got"

FIXTURE="$(mktemp -d)/bad-doc.md"
printf '%s\n' '```bash' 'PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")' 'echo "$PLANS_DIR"' '```' >"$FIXTURE"
probe="$(node "$SCAN" hits "$FIXTURE")"
case "$probe" in
    bad-doc.md#1:*) got=detected ;;
    *) got="$probe" ;;
esac
assert_eq "PL-1c-scanner-detects-a-planted-violation" "detected" "$got"
rm -f "$FIXTURE"

# --- PL-2: PLANS_DIR consumers use the BARE resolver form -------------------------
# id|file|must-contain|must-not-contain (regex; empty field = skip that direction)
# The bare form is one exact literal, so it is matched with grep -F; the forbidden
# capture form varies in quoting, so its side stays a regex.
BARE_FORM='bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"'
while IFS='|' read -r id rel unwanted; do
    [ -z "$id" ] && continue
    f="$AGENTS_DIR/$rel"
    grep -qF -- "$BARE_FORM" "$f" && got=yes || got=no
    assert_eq "$id-uses-bare-resolver" "yes" "$got"
    grep -qE -- "$unwanted" "$f" && got=yes || got=no
    assert_eq "$id-no-variable-capture" "no" "$got"
done <<TABLE
PL-2a|skills/_shared/resolve-plans-dir.md|PLANS_DIR="?[$]\(
PL-2b|skills/session-close/SKILL.md|PLANS_DIR="?[$]\(
PL-2c|skills/survey-code/SKILL.md|PLANS_DIR="?[$]\(
PL-2d|skills/worktree-end/SKILL.md|PLANS_DIR="?[$]\(
PL-2e|docs/ops.md|PLANS_DIR="?[$]\(
TABLE

# --- PL-3: no caller-side `||` fallback duplicating the bridge's own chain ---------
# resolve-plans-dir.md "Fallback chain" forbids it; it also forces the capture form.
for rel in $CHANGED_DOCS; do
    hitn="$(grep -c -E 'workflow-plans-dir"? *2?>?[^|]*\|\|' "$AGENTS_DIR/$rel" || true)"
    assert_eq "PL-3-no-caller-side-fallback-[$rel]" "0" "$hitn"
done

# --- PL-4: the issuance rule still names the capture-then-echo prohibition ---------
RULE="$AGENTS_DIR/rules/shell-commands.md"
for token in '$(...)' 'scratchpad script' 'Write tool'; do
    grep -qF -- "$token" "$RULE" && got=yes || got=no
    assert_eq "PL-4-shell-commands-mentions-[$token]" "yes" "$got"
done

echo ""
echo "prompt-layer: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
