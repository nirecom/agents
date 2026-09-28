#!/usr/bin/env bash
# tests/agents/feature-2100-model-effort-lint.sh
# Tests: agents/outline-planner.md, agents/detail-planner.md, agents/outline-reviewer.md, agents/detail-reviewer.md, agents/test-reviewer.md, agents/plan-security-reviewer.md, agents/security-scanner.md, agents/supervisor-audit.md, agents/supervisor.md, agents/complexity-judge.md, agents/skip-verifier.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/review-docs/SKILL.md, skills/review-tests/SKILL.md, skills/review-plan-security/SKILL.md, skills/review-code-security/SKILL.md, skills/review-code-codex/SKILL.md, skills/review-plan-codex/SKILL.md, skills/commit-push/SKILL.md
# Tags: agents, skills, frontmatter, lint, model-routing, static, scope:issue-specific
# L-1..L-6 (#2100 Step 8c, TL1): model:/effort: frontmatter lint. Only the FIRST
# `---` pair is frontmatter; body mentions never count. L-1/L-2 (codex)/L-3 are
# RED until Step 7 edits the frontmatter; L-4/L-5/L-6 are GREEN today.

set -u
# Anchor to THIS checkout: an inherited AGENTS_DIR would otherwise win in harness.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

WORK="$(make_tmp)"
trap 'rm -rf "$WORK"' EXIT

# fm_extract <file> — print the first `---`...`---` block (CR-stripped); prints
# nothing when line 1 is not `---` or the block never closes.
fm_extract() {
    awk '
        { sub(/\r$/, "") }
        NR == 1 && $0 != "---" { exit }
        NR == 1 { next }
        $0 == "---" { closed = 1; exit }
        { buf = buf $0 "\n" }
        END { if (closed) printf "%s", buf }
    ' "$1"
}

# fm_value <file> <key> — value of <key>: inside the frontmatter ("" when absent).
fm_value() {
    fm_extract "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'
}

# fm_has <file> <key> — 0 when the frontmatter carries <key>:.
fm_has() {
    fm_extract "$1" | grep -qE "^$2:"
}

# lint_absent <label> <rel> <key> — pass when <rel> exists with a frontmatter and no <key>:.
lint_absent() {
    local label="$1" rel="$2" key="$3" f="$AGENTS_DIR/$2"
    if [ ! -f "$f" ]; then
        fail "$label" "$rel missing"
    elif [ -z "$(fm_extract "$f")" ]; then
        fail "$label" "$rel has no frontmatter block"
    elif fm_has "$f" "$key"; then
        fail "$label" "$rel frontmatter still has '$key: $(fm_value "$f" "$key")'"
    else
        pass "$label"
    fi
}

# lint_value <label> <rel> <key> <want>
lint_value() {
    local label="$1" rel="$2" key="$3" want="$4" f="$AGENTS_DIR/$2"
    if [ ! -f "$f" ]; then
        fail "$label" "$rel missing"
    else
        assert_eq "$(fm_value "$f" "$key")" "$want"
    fi
}

# --- L-1: the 9 routed agents carry no model: (the caller passes it) ---------
case_begin "L-1 outline-planner" "agents/outline-planner.md"
lint_absent "L-1 outline-planner has no model:" "agents/outline-planner.md" model
case_end
case_begin "L-1 detail-planner" "agents/detail-planner.md"
lint_absent "L-1 detail-planner has no model:" "agents/detail-planner.md" model
case_end
case_begin "L-1 outline-reviewer" "agents/outline-reviewer.md"
lint_absent "L-1 outline-reviewer has no model:" "agents/outline-reviewer.md" model
case_end
case_begin "L-1 detail-reviewer" "agents/detail-reviewer.md"
lint_absent "L-1 detail-reviewer has no model:" "agents/detail-reviewer.md" model
case_end
case_begin "L-1 test-reviewer" "agents/test-reviewer.md"
lint_absent "L-1 test-reviewer has no model:" "agents/test-reviewer.md" model
case_end
case_begin "L-1 plan-security-reviewer" "agents/plan-security-reviewer.md"
lint_absent "L-1 plan-security-reviewer has no model:" "agents/plan-security-reviewer.md" model
case_end
case_begin "L-1 security-scanner" "agents/security-scanner.md"
lint_absent "L-1 security-scanner has no model:" "agents/security-scanner.md" model
case_end
case_begin "L-1 supervisor-audit" "agents/supervisor-audit.md"
lint_absent "L-1 supervisor-audit has no model:" "agents/supervisor-audit.md" model
case_end
case_begin "L-1 supervisor" "agents/supervisor.md"
lint_absent "L-1 supervisor has no model:" "agents/supervisor.md" model
case_end

# --- L-2: the 8 orchestrator skills pin exactly model: sonnet ----------------
case_begin "L-2 make-outline-plan" "skills/make-outline-plan/SKILL.md"
lint_value "L-2 make-outline-plan" "skills/make-outline-plan/SKILL.md" model sonnet
case_end
case_begin "L-2 make-detail-plan" "skills/make-detail-plan/SKILL.md"
lint_value "L-2 make-detail-plan" "skills/make-detail-plan/SKILL.md" model sonnet
case_end
case_begin "L-2 review-docs" "skills/review-docs/SKILL.md"
lint_value "L-2 review-docs" "skills/review-docs/SKILL.md" model sonnet
case_end
case_begin "L-2 review-tests" "skills/review-tests/SKILL.md"
lint_value "L-2 review-tests" "skills/review-tests/SKILL.md" model sonnet
case_end
case_begin "L-2 review-plan-security" "skills/review-plan-security/SKILL.md"
lint_value "L-2 review-plan-security" "skills/review-plan-security/SKILL.md" model sonnet
case_end
case_begin "L-2 review-code-security" "skills/review-code-security/SKILL.md"
lint_value "L-2 review-code-security" "skills/review-code-security/SKILL.md" model sonnet
case_end
case_begin "L-2 review-code-codex" "skills/review-code-codex/SKILL.md"
lint_value "L-2 review-code-codex" "skills/review-code-codex/SKILL.md" model sonnet
case_end
case_begin "L-2 review-plan-codex" "skills/review-plan-codex/SKILL.md"
lint_value "L-2 review-plan-codex" "skills/review-plan-codex/SKILL.md" model sonnet
case_end

# --- L-3: no effort: in ANY agents/*.md or skills/*/SKILL.md frontmatter -----
case_begin "L-3 effort-free frontmatter (all files)" "skills/review-code-security/SKILL.md"
n=0
bad=""
for f in "$AGENTS_DIR"/agents/*.md "$AGENTS_DIR"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    if fm_has "$f" effort; then
        bad="$bad ${f#"$AGENTS_DIR"/}"
    fi
done
if [ "$n" -eq 0 ]; then
    fail "L-3" "glob matched 0 files — vacuous scan"
elif [ -n "$bad" ]; then
    fail "L-3 no effort: in $n files" "still carrying effort:$bad"
else
    pass "L-3 no effort: in any of $n agent/skill frontmatters"
fi
case_end

# --- L-4: commit-push carries neither key -------------------------------------
case_begin "L-4 commit-push" "skills/commit-push/SKILL.md"
lint_absent "L-4 commit-push has no model:" "skills/commit-push/SKILL.md" model
lint_absent "L-4 commit-push has no effort:" "skills/commit-push/SKILL.md" effort
case_end

# --- L-5: fixed-model agents keep their pins ----------------------------------
case_begin "L-5 complexity-judge" "agents/complexity-judge.md"
lint_value "L-5 complexity-judge" "agents/complexity-judge.md" model opus
case_end
case_begin "L-5 skip-verifier" "agents/skip-verifier.md"
lint_value "L-5 skip-verifier" "agents/skip-verifier.md" model sonnet
case_end

# --- L-6: negative control — the extractor detects planted keys, ignores body -
case_begin "L-6 extractor negative control" "tests/agents/feature-2100-model-effort-lint.sh"
planted="$WORK/planted.md"
printf -- '---\r\nname: x\r\nmodel: haiku\r\neffort: high\r\n---\r\nbody model: opus\r\n' > "$planted"
body_only="$WORK/body-only.md"
printf -- '---\nname: y\n---\nmodel: opus\neffort: low\n---\neffort: high\n---\n' > "$body_only"
unclosed="$WORK/unclosed.md"
printf -- '---\nmodel: opus\neffort: low\n' > "$unclosed"
got="$(fm_value "$planted" model)/$(fm_value "$planted" effort)"
got="$got|$(fm_has "$body_only" model && echo hit || echo miss)/$(fm_has "$body_only" effort && echo hit || echo miss)"
got="$got|$(fm_has "$unclosed" effort && echo hit || echo miss)"
assert_eq "$got" "haiku/high|miss/miss|miss"
# lint_absent itself must FAIL on the planted file; the subshell keeps that
# expected FAIL out of this file's counters.
sub="$( (AGENTS_DIR="$WORK"; PASS=0; FAIL=0; lint_absent "probe" "planted.md" effort; echo "F=$FAIL") | tail -1)"
assert_eq "$sub" "F=1"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
