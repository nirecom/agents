#!/usr/bin/env bash
# tests/agents/feature-2100-model-effort-lint.sh
# Tests: agents/outline-planner.md, agents/detail-planner.md, agents/outline-reviewer.md, agents/detail-reviewer.md, agents/test-reviewer.md, agents/plan-security-reviewer.md, agents/security-scanner.md, agents/supervisor-audit.md, agents/supervisor.md, agents/complexity-judge.md, agents/skip-verifier.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/review-docs/SKILL.md, skills/review-tests/SKILL.md, skills/review-plan-security/SKILL.md, skills/review-code-security/SKILL.md, skills/review-code-codex/SKILL.md, skills/review-plan-codex/SKILL.md, skills/commit-push/SKILL.md
# Tags: agents, skills, frontmatter, lint, model-routing, static, scope:issue-specific
# L-1..L-6 (#2100, TL1): model:/effort: frontmatter lint. Only the FIRST `---`
# pair is frontmatter; body mentions never count. L-1 routed-agent fallback
# model: pins, L-2 orchestrator sonnet pins, L-3 effort-free, L-4 commit-push,
# L-5 fixed-model agents, L-6 extractor negative control.

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

# role_default <role> — the role's default read from ROLE_TABLE (hooks/lib/role-model.js
# owns it), so a changed default moves the expected fallback with it.
role_default() {
    ROLE_MODEL_JS="$(np "$AGENTS_DIR/hooks/lib/role-model.js")" ROLE_NAME="$1" node - 2>/dev/null <<'JS'
const t = require(process.env.ROLE_MODEL_JS).ROLE_TABLE[process.env.ROLE_NAME];
process.stdout.write(t && typeof t.default === "string" ? t.default : "");
JS
}

# lint_role <label> <rel> <role> — frontmatter model: equals the role's ROLE_TABLE
# default; an unreadable default fails instead of matching an absent model: as "".
lint_role() {
    local label="$1" rel="$2" role="$3" want
    want="$(role_default "$role")"
    if [ -z "$want" ]; then
        fail "$label" "ROLE_TABLE default for role '$role' unreadable"
    else
        lint_value "$label (role $role -> $want)" "$rel" model "$want"
    fi
}

# --- L-1: the 9 routed agents keep a frontmatter model: fallback equal to their role default ---
# agent -> role: reviewer = outline/detail/test/plan-security reviewers, security-scanner,
# supervisor-audit; producer-high = outline-planner; producer-low = detail-planner; alert = supervisor.
case_begin "L-1 outline-planner" "agents/outline-planner.md"
lint_role "L-1 outline-planner fallback model:" "agents/outline-planner.md" producer-high
case_end
case_begin "L-1 detail-planner" "agents/detail-planner.md"
lint_role "L-1 detail-planner fallback model:" "agents/detail-planner.md" producer-low
case_end
case_begin "L-1 outline-reviewer" "agents/outline-reviewer.md"
lint_role "L-1 outline-reviewer fallback model:" "agents/outline-reviewer.md" reviewer
case_end
case_begin "L-1 detail-reviewer" "agents/detail-reviewer.md"
lint_role "L-1 detail-reviewer fallback model:" "agents/detail-reviewer.md" reviewer
case_end
case_begin "L-1 test-reviewer" "agents/test-reviewer.md"
lint_role "L-1 test-reviewer fallback model:" "agents/test-reviewer.md" reviewer
case_end
case_begin "L-1 plan-security-reviewer" "agents/plan-security-reviewer.md"
lint_role "L-1 plan-security-reviewer fallback model:" "agents/plan-security-reviewer.md" reviewer
case_end
case_begin "L-1 security-scanner" "agents/security-scanner.md"
lint_role "L-1 security-scanner fallback model:" "agents/security-scanner.md" reviewer
case_end
case_begin "L-1 supervisor-audit" "agents/supervisor-audit.md"
lint_role "L-1 supervisor-audit fallback model:" "agents/supervisor-audit.md" reviewer
case_end
case_begin "L-1 supervisor" "agents/supervisor.md"
lint_role "L-1 supervisor fallback model:" "agents/supervisor.md" alert
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
