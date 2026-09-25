# ===========================================================================
# GROUP A: FORMAT ALLOWLIST (cases 1-9) — TABLE-DRIVEN
# Tests the FORMAT + verdict → exit-code mapping in run-codex-review-loop.
# Per skills/_shared/test-design/parser-regex-tests.md §Table-Driven Tests, allowlist changes
# must be exercised through a table-driven loop. The first column (case-name)
# is injected into every assertion message (Go t.Run(name) equivalent).
#
# Cases 1-6 (new formats security-plan/test-review) fail pre-implementation.
# Cases 7-9 (bad-format→4, detail-plan→0, outline-plan→0) are regressions
# and must pass pre-implementation.
#
# Verdict-body column: the text inside the begin/end-codex-output block.
# A literal '\n' in the body is expanded to a real newline so multi-line
# verdicts (NEEDS_REVISION + concern line) land inside the codex block.
# ===========================================================================
echo ""
echo "=== Group A: FORMAT allowlist + verdict validation (table-driven) ==="

# Table: name | format | verdict-body | want-exit
# Blank lines and lines beginning with '#' are skipped.
while IFS='|' read -r name format verdict_body want; do
  # Trim surrounding whitespace from each field.
  name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  [[ -z "$name" || "$name" == \#* ]] && continue
  format="${format#"${format%%[![:space:]]*}"}"; format="${format%"${format##*[![:space:]]}"}"
  verdict_body="${verdict_body#"${verdict_body%%[![:space:]]*}"}"; verdict_body="${verdict_body%"${verdict_body##*[![:space:]]}"}"
  want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
  run_format_case "$name" "$format" "$verdict_body" "$want"
done << 'FORMAT_TABLE'
# name                     | format        | verdict-body                       | want
1-security-plan-approved   | security-plan | APPROVED                           | 0
2-test-review-approved     | test-review   | APPROVED                           | 0
3-security-plan-needsrev   | security-plan | NEEDS_REVISION\n1. [HIGH] fix this  | 1
4-test-review-needsrev     | test-review   | NEEDS_REVISION\n1. [HIGH] fix this  | 1
5-security-plan-badverdict | security-plan | WHAT_IS_THIS                       | 3
6-test-review-badverdict   | test-review   | WHAT_IS_THIS                       | 3
7-badformat-rejected       | bad-format    | APPROVED                           | 4
8-detail-plan-regression   | detail-plan   | APPROVED                           | 0
9-outline-plan-regression  | outline-plan  | APPROVED                           | 0
FORMAT_TABLE
