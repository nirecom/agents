#!/bin/bash
# Tests: skills/_shared/judge-task-complexity.md, skills/write-code/SKILL.md, CLAUDE.md, .env.example, rules/coding/python.md, rules/coding/nodejs.md
# Tags: skill, bin, env, config, tests, scope:common, lint
# Static grep-based checks for the /write-code skill implementation: SKILL.md
# content, CLAUDE.md's write-code step docs, .env.example's CONFIRM_CODE, and
# module-system SSOT (rules/coding/nodejs.md is canonical; SKILL.md must not
# duplicate it). The script does not abort on individual assertion failures.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Pattern A dispatcher: fragments are sourced in order into this process (one total).
SUITE_DIR="$REPO_ROOT/tests/skills/feature-write-code-skill-static"
. "$SUITE_DIR/_lib.sh"

case_begin "skill-md-content" "skills/write-code/SKILL.md"
. "$SUITE_DIR/a-skill-md-content.sh"
case_end

case_begin "env-and-claude-md" "CLAUDE.md"
. "$SUITE_DIR/b-env-and-claude-md.sh"
case_end

case_begin "coding-rules" "rules/coding/python.md"
. "$SUITE_DIR/c-coding-rules.sh"
case_end

case_begin "complexity-and-gates" "skills/_shared/judge-task-complexity.md"
. "$SUITE_DIR/d-complexity-and-gates.sh"
case_end

case_begin "wcd-7-staging" "skills/write-code/SKILL.md"
. "$SUITE_DIR/e-wcd-7-staging.sh"
case_end

case_begin "lint-recipes" "skills/write-code/SKILL.md"
. "$SUITE_DIR/f-lint-recipes.sh"
case_end

static_finish
